<p align="center"><img src="./image/logo.png" width="30%" alt="Is It Observable"></p>

# Is it Observable

## Episode: Kubernetes Agent Sandboxing — Explained and Observed

> Run an AI agent's untrusted, LLM-generated code on Kubernetes behind a real
> kernel boundary — then observe the thing you just built. This episode covers
> the Kubernetes-SIGs **`agent-sandbox`** project, **gVisor** as the isolation
> runtime, and the honest answer to *"what telemetry do you actually get?"*

This repository accompanies the **Is It Observable** episode on agent sandboxing.
It gives you a reproducible end-to-end stack: a Kubernetes cluster, the
`agent-sandbox` controller, gVisor-isolated agent workloads driven by a real
**OpenClaw** gateway against a **self-hosted Ollama** model, an OpenTelemetry
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
   an optional volume for the workspace. We prove the kernel boundary with a
   single string: `4.19.0-gvisor`.
3. **The lifecycle that makes it cheap.** Warm pools for instant allocation,
   `operatingMode: Suspended` for hibernation, `shutdownTime` for TTL — and what
   each of those actually costs.
4. **What observability data you get.** The full grounded inventory is in
   [`OBSERVABILITY.md`](./OBSERVABILITY.md): rich Prometheus metrics, good
   structured logs, **zero traces** from the controller itself, and **zero
   Kubernetes Events** for the sandbox CRDs. We say so plainly and show the
   workaround.
5. **Four things that will bite you**, all found by running this stack, not by
   reading docs:
   - Setting `spec.env` on a `SandboxClaim` **silently defeats your warm pool**.
   - `/proc` inside gVisor reports the **host's** memory unless you set a limit.
   - The controller's `reconcile_errors_total` has a **permanent non-zero floor**.
   - The controller emits **no Kubernetes Events** for its own CRs.

---

## Prerequisite

- `kubectl`, `helm` v3, and `git`.
- A **Dynatrace** tenant (a free trial works) and two API tokens — created in
  [Getting started](#getting-started) below.
- A model backend: a host running `ollama serve` reachable from the cluster over
  the LAN. The model stays **external** to the cluster (see
  [`TUTORIAL.md` Step 7b](./TUTORIAL.md#step-7b--a-self-hosted-model-and-reaching-the-webui)
  for why — the demo model does not fit on the worker nodes).
- A Kubernetes cluster you control the **nodes** of. gVisor installs `runsc` and
  edits containerd config on every node, so managed control planes with locked
  node images won't work unless they offer gVisor natively (GKE does: use a
  gVisor-enabled node pool and skip the gVisor install step).

> A publication `grep`-gate fails the build on a stray real IP, a `dt0c01.` token
> or a `github_pat_`. Everything in this repo uses documentation placeholders
> (`10.20.30.x`); substitute your own values via the environment variables below.

---

## Getting started

### 1. Dynatrace Tenant — start a trial

If you don't already have one, create a free trial tenant at
[https://www.dynatrace.com/trial](https://www.dynatrace.com/trial). Save your
tenant API base URL (**including the `/api` suffix**):

```bash
# e.g. https://abc12345.live.dynatrace.com/api
export DT_API_URL=https://YOUR_TENANT.live.dynatrace.com/api
```

### 2. Create the Dynatrace API Tokens

You need **two** tokens. Create them under **Access Tokens** in your tenant.

**Operator token** (`DT_OPERATOR_TOKEN`) — used by the Dynatrace Operator /
DynaKube for Kubernetes cluster monitoring via ActiveGate. Scopes:

- `Create ActiveGate tokens`
- `Read entities`
- `Read settings`
- `Write settings`
- `Access problem and event feed, metrics, and topology`
- `Read configuration`
- `Write configuration`
- `PaaS integration - Installer download`

**Ingest data token** (`DT_INGEST_TOKEN`) — used by the **gateway collector** to
export OTLP to Dynatrace. Scopes:

- `Ingest metrics` (`metrics.ingest`)
- `Ingest logs` (`logs.ingest`)
- `Ingest OpenTelemetry traces` (`openTelemetryTrace.ingest`)
- `Ingest events` (`events.ingest`)

Export both — the installer reads them from the environment:

```bash
export DT_OPERATOR_TOKEN=dt0c01.XXXX     # DynaKube / ActiveGate — cluster monitoring
export DT_INGEST_TOKEN=dt0c01.YYYY       # OTLP ingest — used by the collector
```

> No Dynatrace? The whole pipeline is backend-agnostic. Point the collectors'
> `otlphttp` exporter at any OTLP endpoint and drop the DynaKube; you lose the
> ActiveGate cluster-state metrics, which the gateway's `k8s_cluster` receiver
> mostly covers.

### 3. Spin up a k8s cluster

Two documented on-ramps — pick **one**. Everything downstream is identical once
you have a kubeconfig. Because gVisor rewrites containerd on every node, you need
a cluster whose **nodes** you control (Option A), or a managed cluster with a
gVisor-native node pool (Option B, GKE).

#### Option A — Cluster API + Proxmox (CAPMOX, primary)

The homelab reference cluster (`agent-sandbox-demo`): 3 nodes at
4 vCPU / 11.6 GiB, no GPU. You need a **management cluster** with the CAPI +
CAPMOX + in-cluster IPAM providers, a **Proxmox API token** with VM create/clone
rights, and a **CAPMOX-ready golden template** (Ubuntu 24.04 + kubeadm).

```bash
# 3A.1 — provider + cluster inputs. Use your own LAN; the ranges below are
#         documentation placeholders. VIP / node pool / MetalLB pool / DHCP
#         reserve MUST NOT overlap.
export PROXMOX_URL="https://your-proxmox:8006/api2/json"
export PROXMOX_TOKEN="user@pam!tokenid=xxxxxxxx-...-xxxxxxxxxxxx"
export CLUSTER_NAME="agent-sandbox-demo"
export KUBERNETES_VERSION="v1.31.4"
export CONTROL_PLANE_MACHINE_COUNT=1
export WORKER_MACHINE_COUNT=2
export CONTROL_PLANE_ENDPOINT_IP="10.20.30.5"        # your VIP
export NODE_IP_RANGES="10.20.30.10-10.20.30.30"      # node pool
export GATEWAY="10.20.30.1"; export IP_PREFIX=24; export DNS_SERVERS="10.20.30.1"
export TEMPLATE_ID=9000; export PROXMOX_SOURCENODE="pve1"

# 3A.2 — initialize CAPI providers on the MANAGEMENT cluster (once).
clusterctl init --infrastructure proxmox --ipam in-cluster

# 3A.3 — generate + apply the workload-cluster manifests.
clusterctl generate cluster "${CLUSTER_NAME}" \
  --infrastructure proxmox \
  --kubernetes-version "${KUBERNETES_VERSION}" \
  --control-plane-machine-count "${CONTROL_PLANE_MACHINE_COUNT}" \
  --worker-machine-count "${WORKER_MACHINE_COUNT}" \
  > "cluster-${CLUSTER_NAME}.yaml"
kubectl apply -f "cluster-${CLUSTER_NAME}.yaml"

# 3A.4 — wait, then pull the new cluster's kubeconfig.
clusterctl describe cluster "${CLUSTER_NAME}"
clusterctl get kubeconfig "${CLUSTER_NAME}" > "${CLUSTER_NAME}.kubeconfig"
export KUBECONFIG="$PWD/${CLUSTER_NAME}.kubeconfig"

# 3A.5 — install a CNI (Cilium) + a MetalLB pool from your reserved range
#         (e.g. 10.20.30.241-10.20.30.250). The WebUI LoadBalancer in Step 7b
#         draws its address from this pool. GKE users skip this — see Option B.
```

> **gVisor + CNI:** the reference build runs **Cilium**, which is also what the
> "narrow NetworkPolicy allow that opened the whole host" trap in
> [`TUTORIAL.md`](./TUTORIAL.md#trap-3--the-narrow-allow-rule-that-opened-the-whole-host)
> is measured against. On another CNI the egress traps still apply but the
> Cilium-specific `egressDeny` fix does not.

#### Option B — GKE (managed, alternative)

No Proxmox? Bring a managed cluster. GKE ships a CNI + LoadBalancer already, so
you skip Cilium/MetalLB, and it offers gVisor natively — so you also skip the
`runsc` node install and use a **gVisor-enabled node pool** instead.

```bash
# 3B.1 — cluster inputs.
export GCP_PROJECT="your-gcp-project"
export GKE_REGION="europe-west1"
export CLUSTER_NAME="agent-sandbox-demo"
export GKE_MACHINE_TYPE="e2-standard-4"              # 4 vCPU / 16 GB

# 3B.2 — create the cluster with a gVisor (gvisor) sandbox node pool.
gcloud config set project "${GCP_PROJECT}"
gcloud container clusters create "${CLUSTER_NAME}" \
  --region "${GKE_REGION}" \
  --cluster-version "1.31" \
  --release-channel stable
gcloud container node-pools create sandbox \
  --cluster "${CLUSTER_NAME}" --region "${GKE_REGION}" \
  --machine-type "${GKE_MACHINE_TYPE}" --num-nodes 2 \
  --sandbox type=gvisor                              # RuntimeClass "gvisor" provided by GKE

# 3B.3 — pull credentials into your kubeconfig.
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${GKE_REGION}"
```

> On GKE the RuntimeClass `gvisor` already exists, so **skip
> `deploy/gvisor/gvisor.yaml`** — applying the node-installer DaemonSet on locked
> node images is unnecessary and will not work. Everything else is identical.

Either way, confirm `kubectl` is pointed at the **new** cluster before deploying:

```bash
kubectl cluster-info && kubectl config current-context
```

### Deploy the environment

One ordered, idempotent installer stands up the whole stack — the OpenTelemetry
Operator, the Dynatrace Operator + DynaKube (ActiveGate-only), the gVisor
RuntimeClass, the `agent-sandbox` controller, both collectors, and the demo
OpenClaw Sandbox wired to your Ollama endpoint. Every step is `kubectl apply` +
an explicit `kubectl wait`, so it is safe to re-run:

> **Set `OLLAMA_HOST` and `WEBUI_IP` first — and deploy with `deploy.sh`, not a
> bare `kubectl apply -f deploy/agent-sandbox/`.** The manifests ship
> documentation placeholders (`10.20.30.10` = your model host, `10.20.30.20` =
> the WebUI). `deploy.sh` rewrites them from these two variables and **refuses
> to apply** if a placeholder survives. Applied directly, the agent boots
> pointing at a model address that answers nowhere — and nothing in Kubernetes
> tells you why.

```bash
git clone https://github.com/isItObservable/agent-sandbox.git
cd agent-sandbox

export KUBECONFIG="$PWD/agent-sandbox-demo.kubeconfig"
export DT_API_URL=https://YOUR_TENANT.live.dynatrace.com/api
export DT_OPERATOR_TOKEN=dt0c01.XXXX
export DT_INGEST_TOKEN=dt0c01.YYYY
export OLLAMA_HOST=10.20.30.40        # LAN IP of the host running `ollama serve`
export WEBUI_IP=10.20.30.241          # an address from your MetalLB pool for the WebUI

./deploy/deploy.sh
```

| Step | What it installs |
|------|------------------|
| OpenTelemetry Operator | via Helm, for the collector CRDs |
| Dynatrace Operator + DynaKube | `kubernetes-monitoring` (ActiveGate only) — no OneAgent |
| gVisor `runsc` | RuntimeClass + privileged node-installer DaemonSet (**skip on GKE**) |
| `agent-sandbox` **v0.5.2** | controller + extensions (Template/WarmPool/Claim) |
| OTel Collectors | gateway Deployment + node DaemonSet, OTLP → Dynatrace |
| Demo OpenClaw Sandbox | pointed at `OLLAMA_HOST`; WebUI on `WEBUI_IP` |

> On a non-Cilium CNI, `deploy.sh` prints a warning and skips the Cilium-only
> egress-deny policy — the `/32` allow then leaves every port on `OLLAMA_HOST`
> reachable from the sandbox. See Trap 3 in the tutorial.

### Drive the workload

There is no separate load generator: the workload **is** the agent lifecycle.
Apply the lifecycle driver to create a Template + WarmPool + a good claim (adopts
a warm member) + a trap claim (`spec.env`, bypasses the pool) + a TTL sandbox, so
the fleet, warm-pool and isolation dashboards all have live data:

```bash
kubectl apply -f deploy/agent-sandbox/lifecycle-driver.yaml
kubectl get sandbox,sandboxclaim,sandboxwarmpool -n default
```

Then follow [`TUTORIAL.md`](./TUTORIAL.md), which explains each step and shows
what to look for in the telemetry.

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
 │                                                     │  OpenClaw agent  │   │
 │                                                     │  runtimeClass:   │   │
 │                                                     │     gvisor       │   │
 │                                                     │  4.19.0-gvisor   │   │
 │                                                     └────────┬─────────┘   │
 └──────────────────────────────────────────────────────────── │ ───────────┘
        │ CR watch            │ :8080/metrics          │ kubelet │ stats + logs
        │ (k8sobjects)        │ (prometheus)           │         ▼
        ▼                     ▼                        │   self-hosted Ollama
   ╔══════════════════════════════════╗   ╔════════════╧═════════════════════╗
   ║ OTel Collector — GATEWAY         ║   ║ OTel Collector — NODE (DaemonSet) ║
   ║ prometheus · k8s_cluster ·       ║   ║ kubeletstats · filelog            ║
   ║ k8sobjects · otlp :4317/:4318 ◀──╫───╫── in-sandbox agents (SDK)         ║
   ╚═════════════╤════════════════════╝   ╚══════════════════════════════════╝
                 │  OTLP/HTTP
                 ▼
        ┌────────────────────────────────────────────────────┐
        │        Dynatrace  ◀── ActiveGate (DynaKube)         │
        │                       cluster/K8s metrics           │
        └────────────────────────────────────────────────────┘
```

Two egress paths, both auditable: the **Collectors** carry sandbox, controller
and workload telemetry; the **ActiveGate** carries Kubernetes cluster state. The
LLM is **off-cluster** — the sandbox reaches Ollama over the LAN through an
explicit NetworkPolicy allow. There is no OneAgent; this is deliberately not
full-stack.

---

## Repository layout

| Path | What |
|------|------|
| [`TUTORIAL.md`](./TUTORIAL.md) | Ordered, copy-paste walkthrough. **Start here.** |
| [`OBSERVABILITY.md`](./OBSERVABILITY.md) | The grounded telemetry inventory — every signal, observed live. |
| `deploy/deploy.sh` | One-shot installer for the whole stack. |
| `deploy/verify-deploy.sh` | Installer sanity gate — static checks everywhere, plus a live placeholder-leak scan when a cluster is reachable. |
| `deploy/gvisor/` | `runsc` RuntimeClass + privileged node-installer DaemonSet. |
| `deploy/dynatrace/` | ActiveGate-only DynaKube + token secret template. |
| `deploy/agent-sandbox/` | The demo OpenClaw Sandbox + its config/secret template, plus a lifecycle driver (Template + WarmPool + Claims + a TTL sandbox). |
| `deploy/collectors/` | The two OTel Collectors: gateway Deployment + node DaemonSet. |
| [`deploy/dashboards/`](./deploy/dashboards/) | Dynatrace fleet dashboard + `dtctl` install guide. |

---

## Step-by-step: the walkthrough

The full copy-paste walkthrough lives in [`TUTORIAL.md`](./TUTORIAL.md). It builds
the stack one step at a time and, at each step, shows the telemetry to look at:

- **Steps 0–5** — concepts, prerequisites, gVisor, Dynatrace, the controller.
- **Step 6** — your first Sandbox, and proving the kernel boundary (`4.19.0-gvisor`).
- **Step 7 / 7b** — templates, warm pools and claims; then a self-hosted model
  and reaching the OpenClaw WebUI, including the four egress/DNS/auth traps.
- **Step 8** — the two OpenTelemetry Collectors.
- **Step 9** — reading the telemetry: the warm-pool trap, the `/proc` half-truth,
  the error metric that lies, and the missing Events.

---

## Testing / validating the deployment

```bash
# 1. installer sanity (no cluster needed): every mounted secret key is created by
#    every install path, every applied manifest exists, placeholders substituted.
./deploy/verify-deploy.sh

# 2. the stack is up and the demo agent is serving.
kubectl get sandbox,sandboxclaim,sandboxwarmpool -n default
kubectl get pods -n default -l app=openclaw
kubectl get pods -n observability          # gateway + node collectors Running

# 3. warm-pool adoption is demonstrated (good claim adopts; trap claim bypasses).
kubectl get sandboxclaim -n default        # READY=True, SANDBOX bound

# 4. the WebUI is reachable off-cluster (expect 200; 401 on the API is correct).
curl -s -o /dev/null -w "%{http_code}\n" http://${WEBUI_IP}:18789/
```

---

## Observability reference: signals & dashboards

Every signal this stack really emits — and the ones it does **not** — is
inventoried in [`OBSERVABILITY.md`](./OBSERVABILITY.md). The short version:
rich Prometheus metrics from the controller, `kubeletstats` + `filelog` from the
nodes, cluster state from the ActiveGate, **no traces** from the controller
itself (its OTLP endpoint waits for the workload inside the sandbox), and **no
Kubernetes Events** for the sandbox CRDs (worked around with a `k8sobjects` watch).

The story lands on one Dynatrace dashboard, wired to live telemetry:

| Dashboard | File | Focus |
|---|---|---|
| **agent-sandbox — Fleet, Warm Pool & Isolation** | [`agent-sandbox-fleet.dashboard.json`](./deploy/dashboards/agent-sandbox-fleet.dashboard.json) | Fleet inventory by launch type, warm-pool hit rate (the headline trap), per-sandbox CPU/mem, controller reconcile health, and the gVisor isolation markers. |

Install it with **`dtctl`** — full instructions, including the dtctl-ready YAML
form, in [`deploy/dashboards/README.md`](./deploy/dashboards/README.md).

### The headline finding

If you take one thing from this episode, take this:

> **Setting `spec.env` on a `SandboxClaim` silently defeats the warm pool.**

Personalising each agent session with environment variables — the *normal* thing
to do — changes the effective pod template, so no pooled sandbox matches the
pool's `agents.x-k8s.io/sandbox-pod-template-hash` and the claim controller falls
through to a cold create. You get a **0% pool hit rate while still paying for
every pooled pod**. Nothing errors, nothing warns, and no Event records it. The
way to see it is telemetry:

```dql
timeseries sb = avg(agent_sandboxes), by:{launch_type}, filter: owned_by == "SandboxClaim"
```

Pinned at `launch_type="cold"` means your pool is decorative. Full write-up in
[`OBSERVABILITY.md`](./OBSERVABILITY.md#2-the-warm-pool-trap).

---

## Scope & honesty

- **There are no traces** from the controller — it has no OpenTelemetry SDK.
  Spans exist only if the workload *inside* a sandbox creates them; the gateway
  Collector's OTLP endpoint is live and waiting for exactly that.
- **There are no Kubernetes Events** for `Sandbox`, `SandboxClaim`,
  `SandboxTemplate` or `SandboxWarmPool`. `kubectl describe sandbox` has no
  history and Event-based alerting is blind. We work around it with `k8sobjects`.
- **There are no gVisor metrics by default.** `runsc` ships a metric server; the
  standard install does not enable it.
- **From metrics alone you cannot tell a sandboxed pod from a normal one** —
  neither `kubeletstats` nor `k8sattributes` surfaces `runtimeClassName`.
- **Suspend is not checkpoint/restore.** It deletes the pod; resume is a full
  cold start (**~22 s** to a serving OpenClaw gateway on a warm-image node).
- **The `Suspended` condition is never cleared on resume** — a resumed sandbox
  reports `Ready=True` *and* `Suspended=True` at once. Do not alert on `Suspended`.
- **`Ready` means the pod is ready, not that the agent is.** Probe your agent
  images — `demo-agent` reported Ready 14 s before OpenClaw could serve.
- **Pooled state is possible, with a caveat.** Template-level
  `volumeClaimTemplates` is provisioned **per pool member** (StatefulSet-style)
  and *is* warm-pool compatible — it needs a StorageClass/provisioner in the
  cluster. A **per-claim** volume, like a per-claim `spec.env`, bypasses the pool.
- **Under gVisor, `/proc` is only as honest as your limits.** With a memory limit
  set, `MemTotal` is exactly the limit; without one it is the whole node — and
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
kubectl delete -f deploy/gvisor/gvisor.yaml --ignore-not-found   # skip on GKE
helm uninstall dynatrace-operator -n dynatrace
helm uninstall opentelemetry-operator -n opentelemetry-operator-system
```

> Removing `gvisor.yaml` deletes the RuntimeClass and installer DaemonSet but does
> **not** un-install `runsc` from the nodes or revert containerd. On a disposable
> cluster, delete the cluster.

---

## Resources

- `agent-sandbox` project: <https://github.com/kubernetes-sigs/agent-sandbox>
- Docs: <https://agent-sandbox.sigs.k8s.io/docs/>
- Upstream OpenClaw example: <https://agent-sandbox.sigs.k8s.io/docs/use-cases/examples/openclaw-sandbox/>
- Threat model (read before running multi-tenant): <https://github.com/kubernetes-sigs/agent-sandbox/blob/main/docs/security/threat_model.md>
- gVisor: <https://gvisor.dev/docs/>
- `dtctl`: <https://github.com/dynatrace-oss/dtctl>
- Is It Observable: <https://www.youtube.com/@Isitobservable>
