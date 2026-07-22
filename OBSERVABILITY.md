# What observability data you actually get from `agent-sandbox`

**agent-sandbox:** v0.5.2 · **Runtime:** gVisor (`runsc`, guest kernel `4.19.0-gvisor`)
**Pipeline:** OpenTelemetry Collector → OTLP/HTTP → Dynatrace

Every row below was **observed live on a running cluster**, not read from documentation.
If something is marked absent here, we looked for it and it was not there.

This document grounds [`TUTORIAL.md`](./TUTORIAL.md) and the dashboard in
[`deploy/dashboards/`](./deploy/dashboards/).

---

## 0. Executive summary — the shape of the signal

> **agent-sandbox is the mirror image of kagent.**
> kagent — the subject of an earlier Is It Observable episode — emitted **traces + logs and no OTLP metrics**, so its dashboards had to be
> span-derived. agent-sandbox emits **Prometheus metrics + object-watch logs + pod logs,
> and no traces whatsoever**. Dashboards here are metric-derived. Traces exist only if the
> workload *inside* the sandbox creates them.

| Pillar | Source | Verdict |
|---|---|---|
| **Metrics** | controller `:8080/metrics` (Prometheus), kubeletstats, k8s_cluster | ✅ **Rich.** First-class domain metric `agent_sandboxes` |
| **Logs** | controller stdout (structured JSON), k8sobjects CR watch, sandbox pod stdout | ✅ **Good**, after payload surgery (§4) |
| **Traces** | — | ❌ **None.** Controller has no OTel SDK. Only in-sandbox workloads can produce spans |
| **K8s Events** | — | ❌ **None for Sandbox CRs.** Confirmed zero (§3) — this is a real gap |
| **gVisor/runsc** | — | ❌ **None by default.** `runsc` ships a metric server that is not enabled (§6) |

---

## 1. The money metric — `agent_sandboxes`

A point-in-time **gauge** of sandboxes in the cluster. This one metric carries the entire
operational story, because its label set encodes *how* each sandbox came to exist.

```
agent_sandboxes{namespace, created_by, owned_by, sandbox_template, launch_type, expired, ready_condition}
```

| Label | Observed values | Meaning |
|---|---|---|
| `launch_type` | `cold`, `warm` | **cold** = pod created on demand; **warm** = adopted from a `SandboxWarmPool` |
| `owned_by` | `None`, `SandboxWarmPool`, `SandboxClaim` | which controller owns it |
| `created_by` | `controller`, `unknown` | `controller` only for warm-pool members |
| `sandbox_template` | `demo-tpl`, `unknown` | `unknown` for hand-written Sandboxes |
| `expired` | `false`, `true` | past `spec.shutdownTime` |
| `ready_condition` | `true`, `false` | mirrors `status.conditions[Ready]` |

Live series captured during the lifecycle drive:

```
agent_sandboxes{created_by="controller",expired="false",launch_type="warm", owned_by="SandboxWarmPool",ready_condition="true",sandbox_template="demo-tpl"} 2
agent_sandboxes{created_by="unknown",   expired="false",launch_type="cold", owned_by="SandboxClaim",   ready_condition="true",sandbox_template="demo-tpl"} 2
agent_sandboxes{created_by="unknown",   expired="false",launch_type="warm", owned_by="SandboxClaim",   ready_condition="true",sandbox_template="demo-tpl"} 1
agent_sandboxes{created_by="unknown",   expired="false",launch_type="cold", owned_by="None",           ready_condition="true",sandbox_template="unknown"}  2
```

**Cardinality:** bounded and safe — `launch_type`(2) × `expired`(2) × `ready_condition`(2) ×
`created_by`(2) × `owned_by`(3) = 48 combinations per (namespace × template). The only
unbounded dimensions are `namespace` and `sandbox_template`, both operator-controlled.
No dimensional-explosion risk. Scrape it as-is.

---

## 2. ⭐ HEADLINE FINDING — `spec.env` on a SandboxClaim silently defeats the warm pool

This is the most operationally significant thing in the whole capture, and it is
**invisible without this telemetry**.

Two `SandboxClaim`s against the same healthy 2-replica warm pool:

| Claim | `spec.env` set? | Controller decision (log `msg`) | `launch_type` | Time-to-ready |
|---|---|---|---|---|
| `claim-warm` | **yes** (`AGENT_SESSION`) | `"creating sandbox from template"` | `cold` | **6 s** |
| `claim-noenv` | **no** | `"Attempting sandbox adoption"` → `"Successfully adopted sandbox from warm pool"` | `warm` | **instant** |

The warm pool stayed at `readyReplicas: 2` the entire time the env-bearing claims ran — it
was **never touched**. Only the env-free claim adopted a member (`demo-pool-28tsl`), after
which the pool replenished with `demo-pool-v56fc`.

The mechanism is visible in the labels: the pool stamps
`agents.x-k8s.io/sandbox-pod-template-hash: 5c3ff077` on its members. Injecting env vars
changes the effective pod template, so no pooled sandbox matches the hash and the claim
controller falls through to a cold create.

**Why it matters:** a warm pool exists purely to remove cold-start latency for agent
sessions. A platform that personalises each session with env vars — which is the *normal*
thing to do — gets **0% warm-pool hit rate** while the pool still costs full price in
running pods. Nothing errors, nothing warns, and no Kubernetes Event records it (§3). The
metric symptom is `agent_sandboxes{launch_type="cold", owned_by="SandboxClaim"}` staying
pinned at 100%.

The controller *does* state the reason — but at `level: info`, in a single line among
thousands, with no metric counting it:

```
Bypassing warm pool adoption because custom configuration is provided
(env or volume claim templates)
```

Note the parenthetical: **per-claim `volumeClaimTemplates` bypass the pool the same way
`spec.env` does.** That string is the highest-signal thing in the controller's log — it
names the exact claim that bypassed the pool, so it deserves a saved query and an alert.

**→ Dashboard requirement:** a *warm-pool hit rate* tile is the single
highest-value visualisation in this episode:

```dql
timeseries sb = avg(agent_sandboxes), by:{launch_type}, filter: owned_by == "SandboxClaim"
```
…rendered as `warm / (warm + cold)`.

### Proof artefact: negative time-to-ready

Computed from `SandboxClaim.metadata.creationTimestamp` → `status.conditions[Ready].lastTransitionTime`:

| Claim | Created | Ready | Δ |
|---|---|---|---|
| `claim-b` (cold) | 09:01:13 | 09:01:28 | **+15 s** |
| `claim-warm` (cold) | 09:02:33 | 09:02:39 | **+6 s** |
| `claim-noenv` (**warm**) | 09:03:40 | 09:01:24 | **−136 s** |

A **negative** time-to-ready is the cleanest possible proof of a warm-pool hit: the sandbox
was Ready more than two minutes *before the claim that got it existed*. Great on camera.

---

## 3. Kubernetes Events — the gap

**The agent-sandbox controller emits ZERO Kubernetes Events for its own CRDs.** Verified by
enumerating every Event in the cluster:

```
involvedObject kinds: {Pod: 363, ReplicaSet: 7, Deployment: 6, Node: 16,
                       DaemonSet: 22, Lease: 5, PodDisruptionBudget: 1,
                       StatefulSet: 1, DynaKube: 5}
Sandbox / SandboxClaim / SandboxTemplate / SandboxWarmPool events: 0
```

So `kubectl describe sandbox` shows no event history, and any Event-based alerting
(including Dynatrace's built-in Kubernetes events) is blind to sandbox lifecycle. You see
only the *derived* Pod events.

**Compensating control (implemented):** a `k8sobjects` receiver in `watch` mode on all four
CRDs. That turns every CR transition into a log record, which is what §4 processes. This is
the only way to get a sandbox lifecycle stream today.

*Upstream contribution opportunity for the episode: emitting Events on
create/adopt/suspend/expire would be a small, high-value PR.*

---

## 4. Logs

### 4a. Controller stdout — structured JSON, genuinely good
`zap`-style JSON with `level`, `ts`, `msg`, `controller`, `controllerKind`, `reconcileID`,
plus object identity. Directly parseable, no regex needed.

High-value `msg` values to alert/dashboard on:

| `msg` | Signal |
|---|---|
| `Attempting sandbox adoption` / `Successfully adopted sandbox from warm pool` | **warm-pool hit** (carries `sandbox candidate`, `warm pool`, `claim`) |
| `creating sandbox from template` + `Created sandbox for claim` | **warm-pool miss** (carries `duration`, `isReady`) |
| `Creating a new Pod` / `Creating a new Headless Service` | cold-start work |
| `Failed to update sandbox status` | see below |

`Created sandbox for claim` includes a **`duration`** float (0.387 / 0.576 / 1.008 s observed)
— the only latency measurement the controller publishes. Note it measures *API object
creation*, **not** time-to-ready; use the CR timestamps (§2) for real user-facing latency.

### 4b. Known-noisy error: optimistic-concurrency status conflicts

```
"Failed to update sandbox status" ... error: "Operation cannot be fulfilled on
sandboxes.agents.x-k8s.io \"demo-agent\": the object has been modified"
```

Fires on nearly every sandbox creation. It is a benign resource-version race that
self-heals on requeue — **but it is logged at `level: error` with a full stack trace, and it
increments `controller_runtime_reconcile_errors_total{controller="sandbox"}`.**

⚠️ **Do not alert on `controller_runtime_reconcile_errors_total` for the `sandbox`
controller.** It has a permanent non-zero floor from this benign race. Alert on the *rate*
against a baseline, or on `workqueue_depth` instead. This is a textbook "the error metric
lies" case for the tutorial.

### 4c. Sandbox pod stdout
Collected by a `filelog` receiver on the DaemonSet. Nothing special — but it is the **only**
window into what the agent inside the sandbox is doing, since gVisor blocks host-level
introspection.

---

## 5. The k8sobjects payload problem (and the fix)

A raw watch record for one Sandbox is **~3.9 KB**, and roughly 70% of it is
`metadata.managedFields` plus the `kubectl.kubernetes.io/last-applied-configuration`
annotation — server-side bookkeeping with zero analytical value. At watch volume that is
pure ingest cost.

Fix applied in `deploy/collectors/otel-gateway.yaml` (`transform/sandbox_cr`): delete both keys, and lift
the useful fields into flat attributes so the dashboard never has to JSON-parse in DQL.

**Measured result: 3907 bytes → 1084 bytes, a 72% reduction**, with these attributes now
queryable directly:

```
agentsandbox.watch.type      ADDED | MODIFIED | DELETED
agentsandbox.kind            Sandbox | SandboxClaim | ...
agentsandbox.name
agentsandbox.namespace
agentsandbox.launch_type     cold | warm  (null for hand-written Sandboxes — correct)
agentsandbox.operating_mode  Running | Suspended
agentsandbox.ready_reason    DependenciesReady | SandboxSuspended | PodTerminated
agentsandbox.ready_status    True | False
```

---

## 6. gVisor — what you get, and the trap

### What gVisor gives you
`runtimeClassName: gvisor` is visible on the Pod spec and on `Sandbox.spec.podTemplate`.
The guest kernel identifies itself as `4.19.0-gvisor` — that string is the proof the
workload is *not* on the host kernel.

### What gVisor does NOT give you
- **No runsc metrics.** gVisor ships a `runsc metric-server` (sentry syscall counts, memory,
  network) but it is **not enabled** by the standard installer. There is no gVisor-specific
  metric in this cluster today. Enabling it is a follow-up worth its own segment.
- **No runtime attribution in the metric pipeline.** Neither `kubeletstats` nor
  `k8sattributes` surfaces `runtimeClassName`. From the metrics alone **you cannot tell a
  sandboxed pod from a normal one.** Join via the Sandbox CR watch stream (§5), or stamp a
  pod label in the SandboxTemplate and extract it with `k8sattributes`.

### ⚠️ The trap: `/proc` inside gVisor lies about scale

Executed inside a gVisor-sandboxed pod with a 256 Mi limit:

```
$ cat /proc/version
Linux version 4.19.0-gvisor #1 SMP Sun Jan 10 15:06:54 PST 2016
$ head -3 /proc/meminfo
MemTotal:       12248276 kB      <-- the HOST's 12 GiB, not the pod's 256 Mi
MemFree:        12243312 kB
```

**Any agent that self-reports resource usage by reading `/proc` will report host-scale
numbers.** Python's `psutil`, Node's `os.totalmem()`, JVM ergonomics, and most
"how much memory do I have" logic are all wrong inside a sandbox. Worse, a runtime that
sizes its heap from `MemTotal` will size for 12 GiB inside a 256 Mi container and get
OOM-killed.

**→ Always take sandbox resource telemetry from `kubeletstats` (outside), never from the
agent's self-report (inside).** This is the single best "why observability is different in a
sandbox" teaching moment in the episode.

---

## 7. Full controller metric surface

168 metric families on `:8080/metrics`. Grouped by usefulness:

| Group | Families | Keep? |
|---|---|---|
| **agent-sandbox domain** | `agent_sandboxes`, `agent_sandbox_build_info` | ✅ **essential** |
| **controller-runtime** | `controller_runtime_reconcile_{total,errors_total,time_seconds,panics_total}`, `..._active_workers`, `..._max_concurrent_reconciles`, `..._terminal_reconcile_errors_total` | ✅ per-controller (`sandbox`, `sandboxclaim`, `sandboxtemplate`, `sandboxwarmpool`) |
| **workqueue** | `workqueue_{depth,adds_total,retries_total,queue_duration_seconds,work_duration_seconds,longest_running_processor_seconds,unfinished_work_seconds}` | ✅ **saturation signal** — best "is the controller keeping up" metric |
| **webhook** | `controller_runtime_webhook_{requests_total,latency_seconds,requests_in_flight,panics_total}` | ✅ the `/convert` webhook (v1alpha1↔v1beta1) served 60 requests at `code=200` |
| **leader election** | `leader_election_master_status` | ✅ cheap, catches split-brain |
| **certwatcher** | `certwatcher_read_certificate_{total,errors_total}` | ⚠️ low value; webhook cert rotation only |
| **Go runtime** | `go_memstats_*`, `go_gc_*`, `go_sched_*`, `go_memory_classes_*` | ⚠️ keep a handful (`go_goroutines`, `go_memstats_heap_inuse_bytes`) |
| **`go_godebug_non_default_behavior_*`** | **~48 families, permanently 0** | ❌ **drop at the scrape** |
| **histogram detail** | `go_gc_heap_{allocs,frees}_by_size_bytes` (large `le` sets), `go_sched_latencies_seconds`, `go_gc_pauses_seconds` | ❌ drop buckets |

Dropping the `go_godebug_*` families and the oversized Go histograms removes roughly
**60% of the series** for zero operational loss. Implemented as `metric_relabel_configs`
in the Prometheus receiver — dropped at the source, so it costs nothing downstream.

**Observed counters after the lifecycle drive** (a healthy baseline for the dashboard):

```
controller_runtime_reconcile_total{controller="sandbox",        result="success"} 47
controller_runtime_reconcile_total{controller="sandboxclaim",   result="success"} 25
controller_runtime_reconcile_total{controller="sandboxwarmpool",result="success"} 15
controller_runtime_reconcile_total{controller="sandboxtemplate",result="success"}  2
controller_runtime_reconcile_total{controller="sandbox",        result="error"}    1   <-- benign, see §4b
workqueue_depth{...} = 0 for all four controllers
controller_runtime_webhook_requests_total{code="200",webhook="/convert"} 60
```

---

## 8. Sandbox lifecycle state machine (observed)

`Sandbox.status.conditions` is the authoritative lifecycle surface. Observed transitions:

| Trigger | `Ready` | `Suspended` | reason |
|---|---|---|---|
| create → pod running | `True` | — | `DependenciesReady` (`"Pod is Ready; Service Exists"`) |
| `spec.operatingMode: Suspended` | `False` | `True` | `SandboxSuspended` / `PodTerminated` |
| back to `Running` | `True` | — | `DependenciesReady` |

**Suspend deletes the pod outright** (`kubectl get pod` → NotFound), then recreates it on
resume — it is not a checkpoint/restore. Resume measured at **~20 s**, i.e. a full cold
start. Any "suspend idle agent sessions to save money" strategy must budget a cold start on
wake. Worth stating plainly in the tutorial.

Other status fields: `nodeName`, `podIPs`, `service`, `serviceFQDN`, `selector`.

---

## 9. Semantic conventions — `gen_ai.*` vs OpenInference

**Neither applies at the platform layer.** agent-sandbox is infrastructure: it schedules and
isolates sandboxes and has no notion of models, tokens, or prompts. It emits no GenAI
telemetry and defines no semantic convention of its own — its labels
(`agents.x-k8s.io/launch-type`, `.../sandbox-name-hash`) are Kubernetes labels, not OTel
attributes.

GenAI semconv becomes relevant **only one layer up**, if the workload inside a sandbox is an
LLM agent. Guidance, consistent with what we found instrumenting CrewAI and kagent:

- Prefer **`gen_ai.*`** (OTel semconv) — that is what Dynatrace's AI observability keys off.
- **OpenInference** (`llm.*`) appears when instrumenting via Arize/Phoenix or CrewAI's
  default; it needs mapping before Dynatrace will recognise it.
- Where both may appear, use a `coalesce(old, new)` pattern in your queries so one tile spans both.
- **Recommended custom namespace** for platform-level attributes on in-sandbox spans, so the
  agent's traces can be joined to the sandbox that ran them:
  `agentsandbox.sandbox.name`, `agentsandbox.launch_type`, `agentsandbox.template`.

The collector already accepts OTLP on `:4317`/`:4318` for exactly this — the endpoint is
live and unused, waiting for an OTel-instrumented agent inside a sandbox.

---

## 10. Collection architecture as deployed

Two `OpenTelemetryCollector` CRs in ns `observability`. Both verified exporting to Dynatrace
with **zero `send_failed`**.

**Gateway (`agentsandbox`, Deployment ×1)**
| Receiver | Signal | Notes |
|---|---|---|
| `prometheus` | metrics | controller `:8080`, 30 s, `go_godebug_*` dropped at scrape |
| `k8s_cluster` | metrics | cluster object state |
| `k8sobjects` | logs | **watch** on all 4 CRDs + core Events — the Event-gap workaround |
| `otlp` | all | `:4317`/`:4318` for in-sandbox workloads |

**Node agent (`agentsandbox-node`, DaemonSet)**
| Receiver | Signal | Notes |
|---|---|---|
| `kubeletstats` | metrics | per-pod/container CPU, memory, network for sandboxed pods |
| `filelog` | logs | `/var/log/pods`, container parser, self-excluded |

Processor order in every pipeline: **`memory_limiter` → `k8sattributes` → [`transform`] →
`resource` → [`cumulativetodelta`] → `batch`** — memory_limiter first, batch last, as required.
`k8sattributes` is used because this is Kubernetes; `resourcedetection` is deliberately absent
for the same reason.

### Three configuration traps hit and fixed (for the tutorial)

1. **`kubeletstats` cannot run in a Deployment.** `endpoint: https://${K8S_NODE_NAME}:10250`
   fails with `no such host` — node *names* do not resolve in cluster DNS. It must be a
   DaemonSet using `status.hostIP`. This is the most common kubeletstats misconfiguration.
2. **The CRD group is split.** Only `sandboxes` is in `agents.x-k8s.io`;
   `sandboxtemplates`, `sandboxclaims` and `sandboxwarmpools` are all in
   **`extensions.agents.x-k8s.io`**. Getting this wrong yields a silent RBAC `forbidden` on
   the watch — the collector stays `Running` and simply never emits those records.
3. **`k8s_cluster` needs `autoscaling` RBAC** even with no HPAs present, or it log-spams
   `failed to list *v2.HorizontalPodAutoscaler` forever.

### Verified export counters
```
gateway  : sent_metric_points 453   sent_log_records  8    send_failed 0
node     : sent_metric_points 1088  sent_log_records 72    send_failed 0
```

---

---

## 11. What to build on top of this

### Dashboard tiles, in priority order

1. **Warm-pool hit rate** — `agent_sandboxes` by `launch_type` where `owned_by="SandboxClaim"`. **The headline tile**; see §2.
2. **Sandbox inventory** — `agent_sandboxes` by `namespace`, `sandbox_template`, `ready_condition`.
3. **Not-ready sandboxes** — `agent_sandboxes{ready_condition="false"}`; alert if sustained.
4. **Expired but alive** — `agent_sandboxes{expired="true"}`; this is a reclamation leak.
5. **Controller saturation** — `workqueue_depth` + `workqueue_queue_duration_seconds` per controller. **Not** `reconcile_errors_total` (§4b).
6. **Reconcile latency** — `controller_runtime_reconcile_time_seconds` p50/p95 by controller.
7. **Per-sandbox resource usage** — `k8s.pod.cpu.usage` / `k8s.pod.memory.working_set` from `kubeletstats`, never from inside the sandbox (§6).
8. **Lifecycle event stream** — logs on `agentsandbox.watch.type` / `agentsandbox.ready_reason`.
9. **Conversion webhook health** — `controller_runtime_webhook_requests_total` by `code`.

### The four teaching moments

1. **The warm-pool trap** (§2) — env injection silently forces cold starts; negative time-to-ready is the proof.
2. **The `/proc` lie** (§6) — why in-sandbox self-telemetry is wrong and `kubeletstats` is right.
3. **The lying error metric** (§4b) — a permanent non-zero error floor from a benign race.
4. **No Events for CRs** (§3) — and the `k8sobjects` watch as the workaround.

### Open follow-ups

- Enable `runsc metric-server` for genuine gVisor-level telemetry (§6). Currently zero.
- Run an OTel-instrumented agent inside a sandbox to populate the traces pillar — the OTLP endpoint is live and waiting.
- Upstream PR: emit Kubernetes Events on sandbox create / adopt / suspend / expire (§3).

---

## Reproducing this capture

| Path | Contents |
|---|---|
| `deploy/collectors/otel-gateway.yaml` | gateway Collector + RBAC + `transform/sandbox_cr` |
| `deploy/collectors/otel-node-agent.yaml` | DaemonSet Collector (`kubeletstats` + `filelog`) |
| `deploy/agent-sandbox/lifecycle-driver.yaml` | SandboxTemplate + WarmPool + Claims + a TTL sandbox — drives every code path |
| `deploy/agent-sandbox/demo-sandbox.yaml` | a single hand-written Sandbox under gVisor |

Apply the lifecycle driver, wait a few minutes, then scrape the controller and read
the CR watch stream. Everything in this document falls out of that.
