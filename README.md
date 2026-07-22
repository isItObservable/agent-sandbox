<p align="center"><img src="./image/logo.png" width="30%" alt="Is It Observable"></p>

# Kubernetes Agent Sandboxing — Explained and Observed

> Run an AI agent's untrusted, LLM-generated code on Kubernetes behind a real
> kernel boundary — then observe the thing you just built. This episode covers
> the Kubernetes-SIGs **`agent-sandbox`** project, **gVisor** as the isolation
> runtime, and the honest answer to *"what telemetry do you actually get?"*

This repository accompanies the **Is It Observable** episode on agent sandboxing.
It gives you a reproducible end-to-end stack: a Kubernetes cluster, the
`agent-sandbox` controller, gVisor-isolated agent workloads, an OpenTelemetry
Collector pair that harvests every signal the stack really emits, and a single
observability backend.

[![Watch the episode](https://img.shields.io/badge/YouTube-IsItObservable-red?logo=youtube)](https://www.youtube.com/@Isitobservable)

---

## What you will learn

1. **What `agent-sandbox` is and the gap it fills.** Kubernetes has no primitive
   for *one long-lived, stateful pod with a stable identity*. A Deployment is
   stateless and fungible; a StatefulSet is a numbered set. An AI agent session,
   a dev environment, a notebook kernel — those are singletons. `Sandbox` is that
   primitive.
2. **The isolation model.** A Sandbox is just a Pod, so isolation is layered:
   `runtimeClassName: gvisor` for the kernel boundary, NetworkPolicy for egress,
   a PVC for the workspace. We prove the kernel boundary with a single
   string: `4.19.0-gvisor`.
3. **The lifecycle that makes it cheap.** Warm pools for instant allocation,
   `operatingMode: Suspended` for hibernation, `shutdownTime` for TTL — and what
   each of those actually costs.
4. **What observability data you get.** The full grounded inventory is in
   [`OBSERVABILITY.md`](./OBSERVABILITY.md): rich Prometheus metrics, good
   structured logs, **zero traces**, and **zero Kubernetes Events for the
   sandbox CRDs**. We say so plainly and show the workaround.
5. **Four things that will bite you**, all found by running this stack, not by
   reading docs:
   - Setting `spec.env` on a `SandboxClaim` **silently defeats your warm pool**.
   - `/proc` inside gVisor reports the **host's** memory, so any agent that
     self-reports resources is wrong.
   - The controller's `reconcile_errors_total` has a **permanent non-zero
     floor** — alert on it and you will page yourself forever.
   - The controller emits **no Kubernetes Events** for its own CRs.

---

## Reference architecture

```
 ┌───────────────────────────────────────────────────────────────────────────┐
 │  namespace: default                                                        │
 │                                                                            │
 │   SandboxTemplate ──▶ SandboxWarmPool ──(pre-warms)──▶ Sandbox  Sandbox     │
 │                              ▲                            │        │       │
 │   SandboxClaim ──(adopts)────┘                            ▼        ▼       │
 │                                                     ┌──────────────────┐   │
 │                                                     │  agent Pod       │   │
 │                                                     │  runtimeClass:   │   │
 │                                                     │     gvisor       │   │
 │                                                     │  4.19.0-gvisor   │   │
 │                                                     └──────────────────┘   │
 └───────────────────────────────────────────────────────────────────────────┘
        │ CR watch            │ :8080/metrics          │ kubelet stats + pod logs
        │ (k8sobjects)        │ (prometheus)           │ (kubeletstats + filelog)
        ▼                     ▼                        ▼
   ╔══════════════════════════════════╗   ╔══════════════════════════════════╗
   ║ OTel Collector — GATEWAY         ║   ║ OTel Collector — NODE (DaemonSet) ║
   ║ prometheus · k8s_cluster ·       ║   ║ kubeletstats · filelog            ║
   ║ k8sobjects · otlp :4317/:4318 ◀──╫───╫── in-sandbox agents (SDK)         ║
   ╚═════════════╤════════════════════╝   ╚════════════╤═════════════════════╝
                 │  OTLP/HTTP                          │  OTLP/HTTP
                 ▼                                     ▼
        ┌────────────────────────────────────────────────────┐
        │        Dynatrace  ◀── ActiveGate (DynaKube)         │
        │                       cluster/K8s metrics           │
        └────────────────────────────────────────────────────┘
```

Two egress paths, both auditable: the **Collectors** carry sandbox, controller
and workload telemetry; the **ActiveGate** carries Kubernetes cluster state.
There is no OneAgent — this is deliberately not full-stack.

---

## Repository layout

| Path | What |
|------|------|
| [`TUTORIAL.md`](./TUTORIAL.md) | Ordered, copy-paste walkthrough. **Start here.** |
| [`OBSERVABILITY.md`](./OBSERVABILITY.md) | The grounded telemetry inventory — every signal, observed live. |
| `deploy/deploy.sh` | One-shot installer for the whole stack. |
| `deploy/gvisor/` | `runsc` RuntimeClass + privileged node-installer DaemonSet. |
| `deploy/dynatrace/` | ActiveGate-only DynaKube + token secret template. |
| `deploy/agent-sandbox/` | The demo OpenClaw Sandbox + its config/secret template, plus a lifecycle driver (Template + WarmPool + Claims + a TTL sandbox). |
| `deploy/collectors/` | The two OTel Collectors: gateway Deployment + node DaemonSet. |
| `deploy/dashboards/` | Dynatrace dashboard for the sandbox fleet. |

---

## Prerequisites

- A Kubernetes cluster you control the **nodes** of. gVisor installs `runsc` and
  edits containerd config on every node, so managed control planes with locked
  node images won't work unless they offer gVisor natively (GKE does: use a
  gVisor-enabled node pool and skip [Step 3](./TUTORIAL.md#step-3--gvisor-the-kernel-boundary)).
- `kubectl` and `helm` v3.
- A **Dynatrace** tenant plus two tokens — an API token and a data-ingest token
  with `metrics.ingest`, `logs.ingest`, `openTelemetryTrace.ingest`. See
  [`deploy/dynatrace/dynatrace-secret.example.yaml`](./deploy/dynatrace/dynatrace-secret.example.yaml).

> No Dynatrace? Everything here is backend-agnostic. Point the Collectors'
> `otlphttp` exporter at any OTLP endpoint and drop the DynaKube. You lose the
> cluster-state metrics the ActiveGate provides; the `k8s_cluster` receiver in
> the gateway Collector covers most of that gap.

---

## Quick start

```bash
git clone https://github.com/isItObservable/agent-sandbox.git
cd agent-sandbox

export KUBECONFIG=~/.kube/agent-sandbox-demo.kubeconfig
export DT_API_URL=https://<your-tenant>.live.dynatrace.com/api
export DT_OPERATOR_TOKEN=dt0c01....
export DT_INGEST_TOKEN=dt0c01....

./deploy/deploy.sh

# drive the whole lifecycle so there is something to look at
kubectl apply -f deploy/agent-sandbox/lifecycle-driver.yaml
kubectl get sandbox,sandboxclaim,sandboxwarmpool -n default
```

Then follow [`TUTORIAL.md`](./TUTORIAL.md), which explains each step and shows
what to look for in the telemetry.

---

## The headline finding

If you take one thing from this episode, take this:

> **Setting `spec.env` on a `SandboxClaim` silently defeats the warm pool.**

A warm pool exists to remove cold-start latency. Personalising each agent session
with environment variables — the *normal* thing to do — changes the effective pod
template, so no pooled sandbox matches the pool's
`agents.x-k8s.io/sandbox-pod-template-hash` and the claim controller falls
through to a cold create. You get a **0% pool hit rate while still paying for
every pooled pod**. Nothing errors, nothing warns, and no Kubernetes Event
records it. The controller mentions it in one `info` line
(`"Bypassing warm pool adoption because custom configuration is provided"`)
buried among thousands.

The way to see it is telemetry:

```dql
timeseries sb = avg(agent_sandboxes), by:{launch_type}, filter: owned_by == "SandboxClaim"
```

Pinned at `launch_type="cold"` means your pool is decorative. Full write-up and
the measurement — including a **negative time-to-ready**, which is the cleanest
possible proof of a warm-pool hit — in [`OBSERVABILITY.md`](./OBSERVABILITY.md#2-the-warm-pool-trap).

---

## Scope & honesty

- **There are no traces.** The `agent-sandbox` controller has no OpenTelemetry
  SDK. Spans exist only if the workload *inside* a sandbox creates them. The
  gateway Collector's OTLP endpoint is live and waiting for exactly that.
- **There are no Kubernetes Events** for `Sandbox`, `SandboxClaim`,
  `SandboxTemplate` or `SandboxWarmPool`. Verified by enumerating every Event in
  the cluster. `kubectl describe sandbox` has no history and Event-based alerting
  is blind. We work around it with a `k8sobjects` watch.
- **There are no gVisor metrics by default.** `runsc` ships a metric server; the
  standard install does not enable it.
- **From metrics alone you cannot tell a sandboxed pod from a normal one.**
  Neither `kubeletstats` nor `k8sattributes` surfaces `runtimeClassName`.
- **Suspend is not checkpoint/restore.** It deletes the pod. Resume is a full
  cold start (**22 s** measured to a serving OpenClaw gateway, on a node that
  already has the image). Budget for it.
- **The `Suspended` condition is never cleared on resume.** A resumed sandbox
  reports `Ready=True` *and* `Suspended=True` at the same time, indefinitely.
  Do not alert on `Suspended`.
- **`Ready` means the pod is ready, not that the agent is.** Without a readiness
  probe, `demo-agent` reported Ready 14 s before OpenClaw could serve a request —
  and a `SandboxWarmPool` counts the same condition. Probe your agent images.
- **You cannot have both a warm pool and a per-session PVC** on v0.5.2. A PVC in
  the template is shared by every pooled member; a per-claim `volumeClaimTemplates`
  bypasses the pool. Pooled agents get ephemeral state.
- **Under gVisor, `/proc` is only as honest as your limits.** With a memory limit
  set, `MemTotal` is exactly the limit. Without one, it is the whole node — and
  runtimes size their heaps from it.

---

## Cleanup

```bash
kubectl delete -f deploy/agent-sandbox/lifecycle-driver.yaml --ignore-not-found
kubectl delete -f deploy/agent-sandbox/demo-sandbox.yaml --ignore-not-found
kubectl delete secret openclaw-secrets -n default --ignore-not-found
kubectl delete -f deploy/collectors/ --ignore-not-found
kubectl delete -f deploy/dynatrace/dynakube.yaml --ignore-not-found
kubectl delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.5.2/sandbox-with-extensions.yaml
kubectl delete -f deploy/gvisor/gvisor.yaml --ignore-not-found
helm uninstall dynatrace-operator -n dynatrace
helm uninstall opentelemetry-operator -n opentelemetry-operator-system
```

> Removing `gvisor.yaml` deletes the RuntimeClass and the installer DaemonSet but
> does **not** un-install `runsc` from the nodes or revert the containerd config.
> On a disposable cluster, delete the cluster.

---

## Further reading

- `agent-sandbox` project: <https://github.com/kubernetes-sigs/agent-sandbox>
- Docs: <https://agent-sandbox.sigs.k8s.io/docs/>
- Threat model (read this before running multi-tenant): <https://github.com/kubernetes-sigs/agent-sandbox/blob/main/docs/security/threat_model.md>
- gVisor: <https://gvisor.dev/docs/>
- Is It Observable: <https://www.youtube.com/@Isitobservable>
