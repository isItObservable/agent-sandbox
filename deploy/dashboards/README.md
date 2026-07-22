# Dashboards

The Dynatrace dashboard for this episode:
[`agent-sandbox-fleet.dashboard.json`](agent-sandbox-fleet.dashboard.json).

Import it into your tenant (**Dashboards → Upload**), or deploy it with
[`dtctl`](https://github.com/dynatrace-oss/dtctl):

```bash
dtctl apply -f agent-sandbox-fleet.dashboard.json
```

> The export metadata (`id`, `owner`, `version`, `modificationInfo`) has been
> **stripped** from the committed JSON, so importing it always creates a **new**
> dashboard in your tenant rather than updating the one it was exported from.

Every source metric is confirmed present with the pipeline in
[`../collectors/`](../collectors/) — see
[`../../OBSERVABILITY.md`](../../OBSERVABILITY.md) for how each one was verified.
All 16 data tiles were validated against live data before deployment.

## Why this dashboard has no trace tiles

agent-sandbox is the **mirror image of kagent**. kagent emitted traces and logs
and no OTLP metrics, so its dashboards had to be span-derived. agent-sandbox
emits **Prometheus metrics + object-watch logs + pod logs and no traces at
all** — the controller carries no OTel SDK. Everything here is metric- or
log-derived. Traces appear only if the workload *inside* a sandbox creates
them, which is why the collector keeps an OTLP endpoint open on `:4317`/`:4318`.

## ⚠️ Scope every controller-runtime query to your cluster

`workqueue_*` and `controller_runtime_*` are **generic controller-runtime metric
names**. Any other controller-runtime operator shipping metrics to the same
tenant — a Cluster API management cluster, cert-manager, an ingress controller —
publishes series with identical names. During this build the tenant also held a
CAPI management cluster whose `workqueue_depth` sat alongside agent-sandbox's.

Every such tile in this dashboard is therefore scoped twice:

```dql
filter k8s.cluster.name == "agent-sandbox-demo"
   and in(name, {"sandbox", "sandboxclaim", "sandboxtemplate", "sandboxwarmpool"})
```

Change `agent-sandbox-demo` to your own cluster name after importing.

## Tiles

### ⭐ Warm-pool efficiency — the headline

| Tile | Source | Why |
|------|--------|-----|
| **Warm-pool hit rate** | `agent_sandboxes` by `launch_type`, `owned_by="SandboxClaim"` | `warm / (warm + cold)` as a single value. A pool that is never adopted from reads 0% |
| **Warm-pool decision breakdown** | controller stdout, `msg` parsed from JSON | `WARM HIT` vs `BYPASSED (custom config)` vs `COLD CREATE` |
| **Claim-owned sandboxes by launch type** | `agent_sandboxes` by `launch_type` | cold vs warm over time |
| **Per-claim warm-pool verdict** | controller stdout, `msg` + `name` | Names the individual `SandboxClaim` that got bypassed. The proof tile |

Setting `spec.env` (or volume claim templates) on a `SandboxClaim` **defeats the
warm pool**: the env changes the effective pod template hash, no pooled sandbox
matches, and the claim falls through to a cold create while the pool keeps
costing full price.

The failure is silent in *metrics and Events*, but the controller does say so in
its logs, at `info`, buried among thousands of records:

```
Bypassing warm pool adoption because custom configuration is provided
(env or volume claim templates)
```

That single string is what the two log tiles above surface. Details in
[`../../OBSERVABILITY.md`](../../OBSERVABILITY.md) §2.

### Fleet inventory

| Tile | Source |
|------|--------|
| Sandbox inventory by owner and launch type | `agent_sandboxes` by `owned_by`, `launch_type`, `sandbox_template` |
| Readiness — not-ready sandboxes | `agent_sandboxes` by `ready_condition` |
| Expired but still alive (reclamation leak) | `agent_sandboxes` by `expired` |

Charting readiness and expiry **by dimension** rather than filtering to
`ready_condition="false"` / `expired="true"` keeps the tiles populated on a
healthy cluster. A filtered tile renders blank when nothing is broken, which is
indistinguishable from a broken query.

### Controller health

| Tile | Source |
|------|--------|
| Workqueue depth (saturation) | `workqueue_depth` per controller |
| Reconcile duration p95 | `controller_runtime_reconcile_time_seconds` |
| Workqueue wait p95 | `workqueue_queue_duration_seconds` |
| Reconcile throughput by controller and result | `controller_runtime_reconcile_total` |
| Conversion webhook health | `controller_runtime_webhook_requests_total` by `code` |
| Controller error log stream | controller stdout where `level == "error"` |

**Percentiles need an explicit rollup.** The Prometheus histogram arrives as
`controller_runtime_reconcile_time_seconds_bucket` with no `_sum`/`_count`
companion, so a bare `percentile()` fails with *"requires a rollup with the
given metric key(s)"*. These tiles use:

```dql
percentile(controller_runtime_reconcile_time_seconds, 95, rollup: avg)
```

That is a percentile *of per-interval averages*, not a true bucket quantile —
good for trend and comparison across controllers, not for an SLO.

## ⚠️ What NOT to put on this dashboard

**`controller_runtime_reconcile_errors_total{controller="sandbox"}`.**

It has a permanent non-zero floor from a benign optimistic-concurrency race
(`"the object has been modified"`) that self-heals on requeue. Charting it makes
a healthy cluster look broken; alerting on it pages you forever. Use
`workqueue_depth` instead. Details in
[`../../OBSERVABILITY.md`](../../OBSERVABILITY.md) §4b.

The error *log stream* is still on the dashboard, deliberately — as a triage
surface you read after something else told you to look, not as an alert source.

## Sandbox resource usage — measured from outside

`/proc` inside gVisor reports the **host's** memory: a pod with a 256 Mi limit
reads `MemTotal: 12248276 kB`. Anything that self-reports resources from inside
a sandbox (`psutil`, `os.totalmem()`, JVM ergonomics) is wrong, and a runtime
that sizes its heap from `MemTotal` will size for 12 GiB inside a 256 Mi
container and get OOM-killed.

Both resource tiles therefore read `k8s.pod.cpu.usage` and
`k8s.pod.memory.working_set` from **`kubeletstats` on the node DaemonSet** —
outside the sandbox boundary, where the numbers are true. Measured working set
is ~20–25 MiB per sandbox, against the 12 GiB the sandbox believes it has.

**Scoping caveat:** neither `kubeletstats` nor `k8sattributes` surfaces
`runtimeClassName`, and while the `agents.x-k8s.io/sandbox-name-hash` pod label
does reach Dynatrace as `agentsandbox.sandbox.name.hash` in series metadata, it
is **not usable as a `timeseries` split dimension** — grouping by it returns
empty. Sandbox pods are scoped by namespace instead. Adjust the namespace filter
if you run sandboxes outside `default`.

## Sandbox lifecycle stream

The agent-sandbox controller emits **zero Kubernetes Events for its own CRDs**,
so `kubectl describe sandbox` shows no history and Dynatrace's built-in
Kubernetes event alerting is blind to sandbox lifecycle. The CR watch tile is
the compensating control: a `k8sobjects` receiver in **watch** mode over all
four CRDs, with `managedFields` and `last-applied-configuration` stripped
(3907 → 1084 bytes, a 72% reduction) and the useful fields lifted into flat
`agentsandbox.*` attributes so no JSON parsing is needed in DQL.

## Parsing controller logs in DQL

The collector ships controller stdout verbatim — the JSON stays in `content`
and `loglevel` reads `NONE`. Tiles that need `msg` or `level` parse it inline:

```dql
| parse content, "JSON:j"
| fieldsAdd lvl = j[level], msg = j[msg], ctrl = j[controller]
```

Adding a `json_parser` operator to the `filelog` receiver would promote these to
first-class attributes and make the tiles cheaper — a worthwhile follow-up.
