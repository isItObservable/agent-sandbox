# Tutorial — Kubernetes agent sandboxing, end to end

This is the ordered, copy-paste walkthrough for the **Is It Observable** episode on
`agent-sandbox`. By the end you will have AI-agent workloads running inside gVisor
sandboxes on Kubernetes, a warm pool serving them, and an OpenTelemetry pipeline
that tells you honestly what is going on — including the four things that will
bite you.

Every step is a stop in the video. `deploy/deploy.sh` does Steps 2–6 in one shot;
this document explains *why* each one exists and what to look at afterwards.

**Contents**

- [Step 0 — Concepts: why a `Sandbox` and not a Deployment](#step-0--concepts-why-a-sandbox-and-not-a-deployment)
- [Step 1 — Prerequisites and a cluster](#step-1--prerequisites-and-a-cluster)
- [Step 2 — OpenTelemetry Operator](#step-2--opentelemetry-operator)
- [Step 3 — gVisor: the kernel boundary](#step-3--gvisor-the-kernel-boundary)
- [Step 4 — Dynatrace operator + DynaKube](#step-4--dynatrace-operator--dynakube)
- [Step 5 — The `agent-sandbox` controller](#step-5--the-agent-sandbox-controller)
- [Step 6 — Your first Sandbox, and proving the boundary](#step-6--your-first-sandbox-and-proving-the-boundary)
- [Step 7 — Templates, warm pools and claims](#step-7--templates-warm-pools-and-claims)
- [Step 8 — The OpenTelemetry Collectors](#step-8--the-opentelemetry-collectors)
- [Step 9 — Read the telemetry: the four traps](#step-9--read-the-telemetry-the-four-traps)
- [Step 10 — Lifecycle: suspend, resume, expire](#step-10--lifecycle-suspend-resume-expire)
- [Step 11 — Operating guidance](#step-11--operating-guidance)
- [Step 12 — Cleanup](#step-12--cleanup)

---

## Step 0 — Concepts: why a `Sandbox` and not a Deployment

An AI agent session is a **singleton with a name**. It has a workspace it must
keep, a stable address other things call, and a lifetime measured in hours. It is
not fungible and it is not a numbered member of a set.

Kubernetes has no primitive for that:

| Primitive | Shape | Why it doesn't fit |
|---|---|---|
| Deployment | N interchangeable, stateless replicas | An agent's workspace is not interchangeable |
| StatefulSet | ordered, numbered set with stable identity | You want *one*, named for the session, not `agent-0` |
| bare Pod | a singleton | No controller, no lifecycle, no reconciliation |

`agent-sandbox` (a Kubernetes-SIGs project, Apache-2.0) adds the missing one. It
ships **four CRDs**:

| CRD | API group | Role |
|---|---|---|
| `Sandbox` | `agents.x-k8s.io/v1beta1` | The core resource: one stateful pod + stable identity + lifecycle |
| `SandboxTemplate` | `extensions.agents.x-k8s.io/v1beta1` | Reusable pod / volume / network-policy definition |
| `SandboxWarmPool` | `extensions.agents.x-k8s.io/v1beta1` | N pre-warmed Sandboxes for instant allocation |
| `SandboxClaim` | `extensions.agents.x-k8s.io/v1beta1` | A user-facing request that binds a session to a pooled Sandbox |

> ⚠️ **Note the split API group.** Only `sandboxes` lives in `agents.x-k8s.io`.
> The other three are in **`extensions.agents.x-k8s.io`**. This trips up RBAC and
> collector config later — see [Step 8](#step-8--the-opentelemetry-collectors).

The flow: a `SandboxTemplate` describes the agent. A `SandboxWarmPool` stamps out
N of them and keeps them Ready. A user's `SandboxClaim` **adopts** one, so the
session starts instantly instead of waiting for an image pull and a boot.

And the second half of the story: the agent is going to execute code an LLM wrote.
A normal container shares the host kernel with everything else on the node — one
kernel bug away from the rest of your cluster. So we set
`runtimeClassName: gvisor` and give it its own userspace kernel.

```bash
export KUBECONFIG=~/.kube/agent-sandbox-demo.kubeconfig
export DT_API_URL=https://<your-tenant>.live.dynatrace.com/api
export DT_OPERATOR_TOKEN=dt0c01....
export DT_INGEST_TOKEN=dt0c01....
```

---

## Step 1 — Prerequisites and a cluster

**Tools:** `kubectl`, `helm` v3, and a `KUBECONFIG`.

**The one hard requirement: you must control the nodes.** Step 3 installs `runsc`
onto every node and edits the containerd config. That rules out managed offerings
with immutable node images — unless they offer gVisor natively.

| Where you're running | What to do |
|---|---|
| Bare metal / VMs / CAPI / kubeadm | Follow every step. This is what the episode uses. |
| GKE | Use a **gVisor-enabled node pool** and **skip Step 3** entirely. |
| kind / minikube | Works for Steps 2, 4–12, but gVisor needs `runsc` in the node image. Without it, drop `runtimeClassName` from the manifests and you lose the isolation story. |

Any recent Kubernetes with a CNI is fine. This episode was built on a
1 control-plane + 2 worker cluster; nothing here needs more.

**No StorageClass required.** Every manifest here uses `emptyDir` for agent
state, deliberately — see the warm-pool/persistence trade-off in Step 7.

---

## Step 2 — OpenTelemetry Operator

The Operator gives us the `OpenTelemetryCollector` CRD, which is how we deploy
both Collectors in Step 8. Its admission webhook needs TLS certificates; rather
than pull in cert-manager for one dependency, let the chart self-sign.

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
  -n opentelemetry-operator-system --create-namespace \
  --version 0.120.0 \
  --set "manager.image.repository=ghcr.io/open-telemetry/opentelemetry-operator/opentelemetry-operator" \
  --set admissionWebhooks.certManager.enabled=false \
  --set admissionWebhooks.autoGenerateCert.enabled=true \
  --wait
```

> If you already run cert-manager, install it first and drop the two webhook
> flags — that path is better for production.

---

## Step 3 — gVisor: the kernel boundary

This is the step that makes the whole episode meaningful.

gVisor (`runsc`) is a **userspace kernel**. It intercepts the syscalls your
container makes and services them itself, in Go, in user space. The container
never talks to the host kernel directly. When an agent runs LLM-generated code
that tries something clever, the blast radius is a sandboxed process, not your
node.

```bash
kubectl apply -f deploy/gvisor/gvisor.yaml
kubectl -n kube-system rollout status ds/gvisor-installer
```

`deploy/gvisor/gvisor.yaml` contains two things:

1. A **`RuntimeClass` named `gvisor`** with `handler: runsc`. This is the name
   pods reference.
2. A **privileged node-installer DaemonSet** that, on each node, downloads
   `runsc` + `containerd-shim-runsc-v1`, appends the `io.containerd.runsc.v1`
   runtime to the containerd config, and restarts containerd via `nsenter`.

> **Two gotchas baked into that manifest, so you don't rediscover them:**
>
> - The installer script lives inside a YAML block scalar. A shell **heredoc**
>   terminator must sit at column 0, which *ends the block scalar* and makes the
>   whole manifest unparseable (`could not find expected ':'` — and `kubectl`
>   reports the wrong line number). The manifest uses indented `printf` instead.
> - `debian:12-slim` **has no `curl`**. The installer `apt-get install`s
>   `curl ca-certificates` before it does anything else.

Smoke-test the runtime before you build anything on it:

```bash
kubectl run gvisor-smoke --image=busybox --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"gvisor"}}' -- dmesg
kubectl logs gvisor-smoke | head -1
# [    0.000000] Starting gVisor...
```

That banner is the proof. If you don't see it, nothing downstream is isolated.

---

## Step 4 — Dynatrace operator + DynaKube

We keep **two auditable paths** to the backend and no more: the ActiveGate
carries Kubernetes cluster state, and the OTel Collectors (Step 8) carry
everything about the sandboxes themselves. There is **no OneAgent** — the DynaKube
is ActiveGate-only, deliberately not full-stack.

```bash
kubectl create namespace dynatrace --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic agent-sandbox-demo -n dynatrace \
  --from-literal=apiToken="${DT_OPERATOR_TOKEN}" \
  --from-literal=dataIngestToken="${DT_INGEST_TOKEN}"

helm repo add dynatrace https://raw.githubusercontent.com/Dynatrace/dynatrace-operator/main/config/helm/repos/stable
helm repo update
helm upgrade --install dynatrace-operator dynatrace/dynatrace-operator \
  -n dynatrace --version 1.9.0 --set installCRD=true --wait

# set your tenant URL, then apply
sed "s#https://<your-tenant>.live.dynatrace.com/api#${DT_API_URL}#" \
  deploy/dynatrace/dynakube.yaml | kubectl apply -f -

kubectl get dynakube -n dynatrace   # wait for Running
```

> **Gotcha, already fixed in `dynakube.yaml`:** the ActiveGate image is pinned to
> the **public ECR** image (`public.ecr.aws/dynatrace/dynatrace-activegate:…`).
> The tenant-tagged image 404s on pull; the public one works.

Not using Dynatrace? Skip this step entirely and repoint the Collectors' exporter
in Step 8. You lose ActiveGate cluster metrics; the gateway's `k8s_cluster`
receiver covers most of it.

---

## Step 5 — The `agent-sandbox` controller

One apply. No cert-manager needed — the release uses controller-managed webhook
certificates.

```bash
export VERSION=v0.5.2
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${VERSION}/sandbox-with-extensions.yaml
kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller
kubectl get crd | grep agents.x-k8s.io
```

You should see the four CRDs from Step 0. The release ships three assets — pick
`sandbox-with-extensions.yaml` unless you specifically want the core `Sandbox`
CRD without Template/WarmPool/Claim.

The controller also serves a **conversion webhook** between `v1alpha1` and
`v1beta1`. It shows up in the metrics later
(`controller_runtime_webhook_requests_total{webhook="/convert"}`) and is worth a
dashboard tile — a failing conversion webhook breaks every API call to the CRDs.

---

## Step 6 — Your first Sandbox, and proving the boundary

The demo agent is **OpenClaw** (`ghcr.io/openclaw/openclaw:slim`) — a real Node.js
agent gateway, not a sleep-forever placeholder. It needs one model-provider key
and a gateway token:

```bash
kubectl create secret generic openclaw-secrets -n default \
  --from-literal=OLLAMA_API_KEY=ollama-local \
  --from-literal=OPENCLAW_GATEWAY_TOKEN="$(head -c 24 /dev/urandom | base64 | tr -d '/+=')"

# The model backend this config resolves at boot — Step 7b explains why it is
# off-cluster and what to edit. Apply it BEFORE the Sandbox.
kubectl apply -f deploy/agent-sandbox/ollama-endpoint.yaml

kubectl apply -f deploy/agent-sandbox/demo-sandbox.yaml
kubectl wait --for=condition=Ready sandbox/demo-agent --timeout=10m
```

> `OLLAMA_API_KEY=ollama-local` is **not a credential** — it is the literal
> marker OpenClaw expects for a local/LAN Ollama daemon that needs no auth. The
> gateway token on the next line is the real secret. If you point this demo at a
> hosted backend instead, that line becomes `ANTHROPIC_API_KEY` (or
> `GEMINI_`/`OPENAI_`/`OPENROUTER_`) and the key names in `demo-sandbox.yaml`
> and `openclaw-pool.yaml` must change to match — they are mounted by name, and
> a mismatch shows up as `CreateContainerConfigError`, not as a clear message.

> The first pull is **~324 MB**, so on a node that has never seen the image
> expect **~2.5 minutes** before the pod even starts. That number is the whole
> economic argument for the warm pool in Step 7 — keep it in mind.

The manifest is deliberately small — the point is the fields that matter:

```yaml
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: demo-agent
spec:
  operatingMode: Running        # or Suspended — see Step 10
  shutdownPolicy: Retain        # Retain | Delete | DeleteForeground
  service: true                 # controller fronts the pod with a headless Service
  podTemplate:
    spec:
      runtimeClassName: gvisor  # ← THE POINT
      containers:
        - name: agent
          image: ghcr.io/openclaw/openclaw:slim
          # ...
```

Three things in that file are not obvious, and each one is a bug if you skip it:

- **`bind: "lan"` in `openclaw.json`.** OpenClaw binds to loopback by default,
  which works with `kubectl port-forward` and nothing else. Without this the
  Service resolves and then refuses every connection. A non-loopback bind also
  makes gateway auth mandatory — hence the token.
- **`HOME=/workspace`.** The image's default `HOME` is `/home/node`, on the
  read-only image layer. Point `HOME` and `OPENCLAW_STATE_DIR` at a writable
  volume or the gateway cannot persist anything.
- **A `readinessProbe` on `:18789`.** Covered below — it is not cosmetic.

The controller creates one Pod and one headless Service, and reports back on
`status`: `serviceFQDN`, `service`, `podIPs`, `nodeName`, `conditions`.

Now prove the isolation end to end — not on a raw pod this time, but through an
actual `Sandbox`:

```bash
kubectl get pod demo-agent -o jsonpath='{.spec.runtimeClassName}'; echo
# gvisor

kubectl exec demo-agent -c agent -- uname -a
# Linux demo-agent 4.19.0-gvisor #1 SMP Sun Jan 10 15:06:54 PST 2016 x86_64 GNU/Linux
```

**`4.19.0-gvisor`** is the whole story in one string. That is not your node's
kernel version — it is gVisor's synthetic guest kernel identifying itself. A
full Node.js 24 runtime, 7 OpenClaw plugins and a Playwright-capable image are
all running on it. The agent is not on the host kernel.

Confirm the gateway is actually serving, from another pod, through the Service:

```bash
kubectl run reach --image=busybox:1.36 --restart=Never --rm -it -- \
  wget -S -O- http://demo-agent.default.svc.cluster.local:18789/
# HTTP/1.1 200 OK
```

### The readiness lie ⚠️

`Sandbox` reports `Ready` when the **pod** is ready. With no probe, the pod is
"ready" the moment the container process starts — but OpenClaw needs to load
config, resolve auth, start its HTTP server and pre-warm its provider auth and
plugin runtime before it can answer anything. Measured on this cluster:

| Event | Without a readiness probe |
|---|---|
| pod Ready / `Sandbox` Ready | **8 s** |
| OpenClaw actually serving | **22 s** |

That is a **14-second window where the platform advertises an agent that will
refuse your request** — and it is worse than it looks, because a `SandboxWarmPool`
counts the same condition. A pool can hand a claim a member that is not serving.

The fix is one block, already in `demo-sandbox.yaml`:

```yaml
readinessProbe:
  httpGet: { path: /, port: 18789 }
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 30
```

With it, `Sandbox` Ready lands at **24 s** — slower on paper, honest in practice.
**Put a real readiness probe on every agent image you pool.** A `Ready` condition
you cannot trust is worse than no condition at all.

> **Access note:** with gVisor or Kata, direct `kubectl port-forward` to the
> sandbox pod is **not supported**. Upstream ships a **Sandbox Router** — a
> reverse proxy that routes on an `X-Sandbox-ID` header — and the Python SDK uses
> it. If you expose sandboxes to users, the router becomes a production
> dependency, so monitor it like one.

> **Benign log line:** OpenClaw logs `failed to promote config last-known-good
> backup: EROFS` because `openclaw.json` is mounted from a read-only ConfigMap.
> That is the correct trade — config stays declarative — and the gateway still
> reaches `ready`.

---

## Step 7 — Templates, warm pools and claims

A single hand-written `Sandbox` is the demo. A platform uses the other three CRDs.

```bash
kubectl apply -f deploy/agent-sandbox/lifecycle-driver.yaml
kubectl get sandbox,sandboxclaim,sandboxwarmpool -n default
```

That one file gives you the whole state space, on purpose — the telemetry in
Step 9 is only interesting if every code path has actually fired:

| Object | Exercises | What it moves in the telemetry |
|---|---|---|
| `SandboxTemplate demo-tpl` | template reconcile | `agent_sandboxes{sandbox_template=…}` |
| `SandboxWarmPool demo-pool` (replicas: 2) | pre-warmed creation | `agent_sandboxes{launch_type="warm"}`, `workqueue_*` |
| `SandboxClaim claim-a`, `claim-b` | claim → bind | `agent_sandboxes{created_by,owned_by}` |
| `Sandbox ttl-victim` | `shutdownTime` expiry | `agent_sandboxes{expired="true"}` |

The workload inside each sandbox burns a little CPU and writes to stdout on a
loop, so `kubeletstats` and `filelog` have something real to report. Idle pods
make for a useless dashboard.

Watch a claim bind:

```bash
kubectl -n agent-sandbox-system logs deploy/agent-sandbox-controller | grep -i adopt
# "Attempting sandbox adoption"
# "Successfully adopted sandbox from warm pool"
```

That second line is a **warm-pool hit**. Hold onto it — Step 9 is about the case
where you never see it.

### Pooling a *real* agent image

The lifecycle driver uses a tiny image so the state space is quick to exercise.
Pooling OpenClaw works identically, with one rule that decides whether the pool
functions at all:

```bash
kubectl apply -f deploy/agent-sandbox/openclaw-pool.yaml
```

**Everything the agent needs to be born configured goes in the `SandboxTemplate`.**
The secret ref, the ConfigMap mount and the workspace volume all belong in
`spec.podTemplate` — exactly the same block as `demo-sandbox.yaml`. Then a claim
is empty:

```yaml
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: oc-claim-warm
spec:
  warmPoolRef:
    name: openclaw-pool     # and nothing else
```

Verified on this cluster: an empty claim against an OpenClaw pool adopts a warm
member that is already a fully booted, serving gateway. Add a single `spec.env`
entry to that claim and it cold-starts instead (§9a).

> **The persistence trade-off, stated plainly.** OpenClaw's own install guide
> gives each instance a 10 Gi PVC. You cannot have that *and* a warm pool: a PVC
> named in the template is one volume shared by every pooled member (and RWO
> means they will not even schedule together), while a per-claim
> `volumeClaimTemplates` bypasses the pool exactly like `spec.env` does. So:
> **pooled agents get ephemeral `emptyDir` state**, and anything that must
> survive goes to an external store the agent talks to over the network. If you
> genuinely need a per-session PVC, set `replicas: 0` and accept cold starts —
> a pool you always bypass is pure cost. That is a real limitation of
> agent-sandbox v0.5.2, not a configuration mistake.

---

## Step 7b — A self-hosted model, and reaching the WebUI

Up to here the agent has had a placeholder provider key. Two things change when
you point it at a real, self-hosted backend and put its WebUI on a screen: the
model moves off a hosted API onto Ollama, and the gateway has to be reachable
from a browser outside the cluster. Neither is hard. Both are blocked by
defaults that fail *quietly*, and all four traps below were found by running
this, not by reading it.

```bash
kubectl apply -f deploy/agent-sandbox/ollama-endpoint.yaml     # where the model lives
kubectl apply -f deploy/agent-sandbox/openclaw-netpol.yaml     # traps 1 + 2
kubectl apply -f deploy/agent-sandbox/openclaw-netpol-cilium.yaml  # trap 3 (Cilium)
kubectl apply -f deploy/agent-sandbox/openclaw-ui-service.yaml # the WebUI
```

### First, does the model even fit?

Check before you write any YAML, because the answer is usually no:

```console
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
control-plane   4   3.7Gi
worker-1        4   11.6Gi
worker-2        4   11.6Gi
```

A 32B model at q4 is ~20 GB of weights (`qwen3:32b` is 20.2 GB from the Ollama
registry — check with `curl -s https://registry.ollama.ai/v2/library/qwen3/manifests/32b`).
It does not fit in 11.6 GiB at any quantisation, there is no GPU, and on CPU it
would answer at roughly 1–2 tokens/second even if it did. So Ollama runs on a
host with the RAM for it and the sandbox reaches it over the LAN. If you want
the model in-cluster instead, `qwen3:8b` is 5.2 GB and fits — every trap below
still applies, because they are about DNS and egress, not about model size.

`ollama-endpoint.yaml` is a Service with **no selector** plus a hand-written
`EndpointSlice` carrying the LAN address. That keeps the address out of
`openclaw.json`: the config names `ollama.default.svc.cluster.local`, and moving
the model host is an EndpointSlice edit rather than a config change that would
recycle every pooled sandbox.

### Trap 1 — the sandbox does not use cluster DNS

A template-derived sandbox is born with public resolvers and no cluster DNS:

```console
$ kubectl get pod openclaw-pool-xxxxx -o jsonpath='{.spec.dnsPolicy}{.spec.dnsConfig}'
None{"nameservers":["8.8.8.8","1.1.1.1"]}
```

So every in-cluster Service name is `ENOTFOUND` from inside the sandbox —
including the one its model backend lives at. A bare `Sandbox` like `demo-agent`
gets `dnsPolicy: ClusterFirst` and resolves perfectly, which is exactly why this
survives testing: **it works on the single sandbox and breaks when you move to
the pool.** Set it explicitly in the template:

```yaml
spec:
  podTemplate:
    spec:
      dnsPolicy: ClusterFirst
```

### Trap 2 — the generated NetworkPolicy blocks your own network

A `SandboxTemplate` makes the controller write a NetworkPolicy for you. Read it:

```yaml
egress:
- to:
  - ipBlock:
      cidr: 0.0.0.0/0
      except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16]
```

"The internet, yes; anything private, no" — a defensible default for untrusted
code, and it takes out *both* halves of a self-hosted backend at once, because
kube-dns (10.96.0.10) and a LAN Ollama (10.0.0.x) are both RFC1918. Measured
from a live pool member: DNS `ENOTFOUND`, `connect 10.0.0.230:6443` timeout.
The same rule blocks the WebUI, from the other direction — ingress is admitted
only from the in-cluster `sandbox-router`, so a LoadBalancer reaches the pod and
the packet is dropped and the browser simply hangs.

You cannot edit the generated policy; the controller owns it and reverts you.
NetworkPolicy allows are additive, so `openclaw-netpol.yaml` unions the holes
back in: DNS, the model backend on one `/32` and one port, and `:18789` from the
LAN. Note what it selects on — `app: openclaw`, a label we set ourselves in
`podTemplate.metadata` — and **not**
`agents.x-k8s.io/sandbox-template-ref-hash`. That hash is derived from the
template's contents, so keying a policy to it means the policy silently stops
matching anything the next time you edit the template.

What the agent sees when this is wrong is the worst part: the model call hangs
until it times out, so on camera you get an agent that thinks forever, not an
error.

### Trap 3 — the narrow allow rule that opened the whole host ⚠️

`openclaw-netpol.yaml` allows `10.0.0.189/32` on port `11434` and nothing else.
Read as written that is airtight. Measured from inside the sandbox with only
that policy applied:

| target | result |
|---|---|
| `10.0.0.189:11434` | open — the model backend, as intended |
| `10.0.0.189:22` | **open** — SSH on the model host |
| `10.0.0.189:11435` | `ECONNREFUSED` — host reached, port simply shut |
| `10.0.0.230:22` (control-plane) | timeout — still blocked |
| `10.0.0.232:22` (worker) | timeout — still blocked |

Only the address we named opened up, and it opened on **every port**, to a
sandbox whose entire purpose is running code somebody else wrote. Naming
`10.0.0.189/32` gives Cilium a distinct identity for that address, which the
other policy's `0.0.0.0/0` rule then matches — the `except` stops covering it.
Our port restriction only ever constrained *our* rule.

The general shape is worth keeping: under Kubernetes NetworkPolicy, allows
union and there is no way to say "and nothing else", so adding a rule can only
widen. **After writing a narrow allow, do not check that the traffic you wanted
works — it will. Check what else just became reachable.** `nc -z <host> 22` from
inside the sandbox is a five-second test that catches this.

Cilium's `egressDeny` is the missing "and nothing else" (deny beats allow) and
is what `openclaw-netpol-cilium.yaml` applies, as the two port ranges either
side of 11434. Not on Cilium? Then put Ollama on a host that runs nothing you
would mind a sandbox reaching, and treat "named in an `ipBlock`" as "fully
exposed" — an architecture decision rather than a policy one.

### Trap 4 — the WebUI loads and then cannot log in

The controller's `service: true` Service cannot be used for this:

```console
$ kubectl get svc demo-agent
NAME         TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
demo-agent   ClusterIP   None         <none>        <none>    102m
```

Headless, no ports — it exists so an in-cluster router can resolve the pod, and
there is no field on the `Sandbox` to promote it. So you add your own Service,
and `kubectl port-forward` is not a fallback because the gVisor sandbox does not
support it. The selector needs care too: the controller stamps only
`agents.x-k8s.io/sandbox-name-hash=<opaque>`, so there is no readable
`sandbox-name` label to match. `demo-sandbox.yaml` sets `app: openclaw` /
`role: ui` in `podTemplate.metadata` — which the controller does propagate to
the pod — and the Service selects those.

Then the last trap, which only appears in a browser and never in `curl`. Since
v2026.2.26 OpenClaw refuses Control-UI authentication from any origin not in
`gateway.controlUi.allowedOrigins`, and on a non-loopback bind it seeds that
list with localhost only. You will find this in the gateway log:

```
[gateway] seeded gateway.controlUi.allowedOrigins ["http://localhost:18789",
"http://127.0.0.1:18789"] for bind=lan (required since v2026.2.26)
```

The page loads, looks perfect and cannot authenticate. Add the real origin:

```json
"gateway": {
  "bind": "lan",
  "auth": { "mode": "token" },
  "controlUi": { "allowedOrigins": ["http://10.0.0.241:18789"] }
}
```

**That makes the LoadBalancer address part of the agent's configuration**, so
pin it (`spec.loadBalancerIP`) rather than letting MetalLB auto-assign — a
cluster rebuild that hands you `.242` breaks the login with no error that points
at the cause.

### Before you leave it running

This publishes an agent that executes code onto your LAN. The gateway binds
non-loopback, which makes token auth mandatory; verify it is actually enforced
rather than assuming:

```console
$ curl -s -o /dev/null -w '%{http_code}\n' -X POST http://10.0.0.241:18789/tools/invoke \
    -H 'Content-Type: application/json' -d '{"tool":"bash","args":{"command":"id"}}'
401
```

401 is the answer you want. The SPA shell, `/health` and `/status` are public by
design and return 200 unauthenticated — that is the UI bootstrapping itself, not
a hole; `/tools/invoke` and `/api/channels/*` are the surfaces that matter, and
they are fail-closed. A 200 from `/tools/invoke` means anyone on the LAN owns
the sandbox.

Keep the token off camera: paste it off-recording or pre-authenticate the tab
before you hit record.

---

## Step 8 — The OpenTelemetry Collectors

Two Collectors, because one shape cannot do both jobs.

```bash
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic dynatrace-otlp -n observability \
  --from-literal=dataIngestToken="${DT_INGEST_TOKEN}"

for f in deploy/collectors/otel-gateway.yaml deploy/collectors/otel-node-agent.yaml; do
  sed "s#https://<your-tenant>.live.dynatrace.com/api#${DT_API_URL}#" "$f" | kubectl apply -f -
done
kubectl get pods -n observability
```

**Gateway (`agentsandbox`, Deployment ×1)** — cluster-scoped sources:

| Receiver | Signal | What it gets |
|---|---|---|
| `prometheus` | metrics | the controller's `:8080/metrics` — `agent_sandboxes`, controller-runtime, workqueue |
| `k8s_cluster` | metrics | cluster object state |
| `k8sobjects` | logs | **watch** on all four CRDs — the workaround for the missing Events |
| `otlp` | all | `:4317` / `:4318`, for workloads *inside* sandboxes |

**Node agent (`agentsandbox-node`, DaemonSet)** — node-local sources:

| Receiver | Signal | What it gets |
|---|---|---|
| `kubeletstats` | metrics | per-pod/container CPU, memory, network for sandboxed pods |
| `filelog` | logs | `/var/log/pods` — the only window into the agent inside the sandbox |

Processor order in every pipeline is `memory_limiter` → `k8sattributes` →
`[transform]` → `resource` → `[cumulativetodelta]` → `batch`. Memory limiter
first, batch last, always. `k8sattributes` is in because this is Kubernetes;
`resourcedetection` is deliberately out for the same reason.

### Three configuration traps, already fixed in these manifests

1. **`kubeletstats` cannot run in a Deployment.** `endpoint:
   https://${K8S_NODE_NAME}:10250` fails with `no such host` — node *names* do
   not resolve in cluster DNS. It must be a DaemonSet using `status.hostIP`.
   This is the single most common kubeletstats misconfiguration.
2. **The CRD group is split** (Step 0). Grant RBAC on `sandboxes` in
   `agents.x-k8s.io` **and** on `sandboxtemplates` / `sandboxclaims` /
   `sandboxwarmpools` in `extensions.agents.x-k8s.io`. Get it wrong and you get a
   silent `forbidden` on the watch: the Collector stays `Running` and simply
   never emits those records. No crash, no obvious error.
3. **`k8s_cluster` needs `autoscaling` RBAC** even with zero HPAs in the cluster,
   or it log-spams `failed to list *v2.HorizontalPodAutoscaler` forever.

### Two cost decisions worth copying

- The controller ships ~48 `go_godebug_non_default_behavior_*` families that are
  permanently `0`, plus some very wide Go histograms. `metric_relabel_configs`
  drops them **at the scrape** — about **60% of the series gone** for zero
  operational loss, and it costs nothing downstream because it never leaves the
  receiver.
- A raw `k8sobjects` watch record for one Sandbox is ~3.9 KB, ~70% of which is
  `managedFields` and the `last-applied-configuration` annotation. The
  `transform/sandbox_cr` processor deletes both and lifts the useful fields into
  flat attributes: **3907 → 1084 bytes, a 72% reduction**, and your queries never
  have to JSON-parse. The attributes it produces:

  ```
  agentsandbox.watch.type      ADDED | MODIFIED | DELETED
  agentsandbox.kind            Sandbox | SandboxClaim | …
  agentsandbox.name / .namespace
  agentsandbox.launch_type     cold | warm
  agentsandbox.operating_mode  Running | Suspended
  agentsandbox.ready_reason    DependenciesReady | SandboxSuspended | PodTerminated
  agentsandbox.ready_status    True | False
  ```

Confirm data is actually leaving:

```bash
kubectl -n observability logs deploy/agentsandbox-collector | grep -i "send_failed\|Exporting failed"
# (silence is the correct output)
```

---

## Step 9 — Read the telemetry: the four traps

Full inventory in [`OBSERVABILITY.md`](./OBSERVABILITY.md). Here are the four
findings that only show up when you actually run this.

### 9a. The warm-pool trap ⭐

**Setting `spec.env` — or `volumeClaimTemplates` — on a `SandboxClaim` silently
defeats the warm pool.**

Two claims, same healthy 2-replica pool:

| Claim | `spec.env`? | Controller log | `launch_type` | Time-to-ready |
|---|---|---|---|---|
| `oc-claim-env` | **yes** | `"creating sandbox from template"` | `cold` | **+6 s** |
| `oc-claim-warm` | **no** | `"Successfully adopted sandbox from warm pool"` | `warm` | **−86 s** |

Measured with the real OpenClaw image, both claims against the same
`openclaw-pool`. A **negative** time-to-ready is the cleanest possible proof of a
pool hit: the sandbox was Ready a minute and a half before the claim that got it
existed.

Two honest caveats about those numbers, because they are easy to over-read:

- **The magnitude of the negative number means nothing.** It is just how long that
  pool member happened to sit idle before a claim arrived. Reproduce this and you
  will get a different value. **The sign is the finding**, not the size.
- **`+6 s` is a warm-*image* cold start.** The node already had the 324 MB
  OpenClaw image cached. On a node seeing it for the first time the same cold path
  took **~2.5 minutes**. The pool absorbs the image pull too — which is most of
  what it is actually buying you.

A pool hit also skips work *inside* the agent, not just the pod lifecycle. The
adopted member had already logged `provider auth state pre-warmed` and
`agent runtime plugins pre-warmed` before the claim existed: ~4 seconds of
OpenClaw startup the user never waits for.

The mechanism is in the labels. The pool stamps
`agents.x-k8s.io/sandbox-pod-template-hash` on its members. Injecting env vars
changes the effective pod template, no pooled member matches the hash, and the
claim controller falls through to a cold create. The pool sits at
`readyReplicas: 2`, untouched, the whole time.

**Nothing errors and nothing warns.** You get a 0% hit rate at full pool cost,
and personalising a session with env vars is the *normal* thing to do.

The controller does say what it did — but at `info`, in one line, buried among
thousands:

```
Bypassing warm pool adoption because custom configuration is provided
(env or volume claim templates)
```

So it is *technically* logged and *practically* invisible: nothing surfaces it,
no metric counts it, and no Kubernetes Event records it (§9d). That string is
worth a saved query and an alert of its own — it names the exact claim that
bypassed the pool. Reproduce it:

```bash
kubectl get sandbox -o custom-columns=\
NAME:.metadata.name,LAUNCH:.metadata.labels.agents\\.x-k8s\\.io/launch-type

kubectl -n agent-sandbox-system logs deploy/agent-sandbox-controller \
  | grep -i "Bypassing warm pool"
```

The dashboard tile:

```dql
timeseries sb = avg(agent_sandboxes), by:{launch_type}, filter: owned_by == "SandboxClaim"
```

rendered as `warm / (warm + cold)`. Pinned at cold = your pool is decorative.

**Fix:** don't personalise through `spec.env` or per-claim `volumeClaimTemplates`.
Pass session config through a mounted Secret/ConfigMap the template already
references, or through the agent's own API after adoption. If you must use env,
size the pool to zero and accept cold starts — at least you stop paying for pods
nobody adopts.

### 9b. The `/proc` half-truth

gVisor synthesises `/proc` rather than passing the host's through. What it puts
there depends entirely on whether **you set a memory limit**:

```bash
# a sandbox WITH limits.memory: 1Gi
kubectl exec demo-agent -c agent -- head -1 /proc/meminfo
# MemTotal:        1048576 kB     ← exactly the limit. Correct.

# the same image with NO memory limit
kubectl exec openclaw-nolimit -- head -1 /proc/meminfo
# MemTotal:       12248276 kB     ← the HOST's 12 GiB
```

**Set a limit and gVisor tells the truth. Omit one and every "how much memory do
I have" call inside the sandbox reports the whole node.** The same applies to CPU:
`nproc` returns the limit-derived count when set, and the host's core count when
not.

This is not academic, because runtimes size their heaps from exactly these
numbers. The same OpenClaw image, same node, only the limit differs:

| | `limits.memory: 1Gi` | no limit |
|---|---|---|
| `os.totalmem()` | 1 GiB | **11.68 GiB** |
| V8 heap limit | 560 MB | **2240 MB** |
| `os.cpus().length` | 2 | 4 |

An unlimited sandbox lets Node grow a 2.2 GB heap on a node that is also running
everyone else's agents. Python's `psutil`, JVM ergonomics and Go's
`GOMAXPROCS` all read the same synthetic files and reach the same wrong
conclusion.

**Two rules:**

1. **Always set `requests` *and* `limits` on sandbox containers.** Under gVisor
   the limit is not just a cgroup ceiling — it is the only thing that makes
   `/proc` honest.
2. **Take sandbox resource telemetry from `kubeletstats` — from outside — never
   from the agent's self-report from inside.** Even with limits set, you are
   trusting the workload to report on itself.

> **Note for anyone reading an older version of this repo:** an earlier draft
> claimed `MemTotal` always reports the host's 12 GiB, citing a 256 Mi sandbox.
> That was measured on a pod with **no memory limit** and the conclusion was
> over-generalised. Re-measured: a 256 Mi-limited gVisor pod reports exactly
> `262144 kB`. The trap is real, but it is *caused by the missing limit*.

### 9c. The error metric that lies

```
"Failed to update sandbox status" … "the object has been modified"
```

This fires on nearly every sandbox creation. It is a benign optimistic-concurrency
race that self-heals on requeue — **but it is logged at `level: error` with a full
stack trace and it increments
`controller_runtime_reconcile_errors_total{controller="sandbox"}`.**

⚠️ **Do not alert on that counter.** It has a permanent non-zero floor. Alert on
**`workqueue_depth`** instead — that is the real "is the controller keeping up"
signal, and it sat at `0` for all four controllers throughout our run.

### 9d. No Kubernetes Events for the CRDs

Enumerate every Event in the cluster and you find Pod: 363, DaemonSet: 22,
Node: 16, … and **Sandbox / SandboxClaim / SandboxTemplate / SandboxWarmPool: 0**.

The controller emits none. So `kubectl describe sandbox` has no history, and any
Event-based alerting — including your platform's built-in Kubernetes events — is
blind to sandbox lifecycle. You see only the *derived* Pod events.

The `k8sobjects` watch from Step 8 is the compensating control: every CR
transition becomes a log record. Today it is the only way to get a sandbox
lifecycle stream.

> *Good first upstream contribution: emitting Events on
> create / adopt / suspend / expire would be a small, high-value PR.*

### And what simply isn't there

- **No traces.** The controller has no OTel SDK. Spans exist only if the workload
  *inside* a sandbox makes them — the gateway's OTLP endpoint
  (`agentsandbox-collector.observability.svc:4317`) is live and waiting.
- **No gVisor metrics.** `runsc` ships a `metric-server` (sentry syscall counts,
  memory, network); the standard install does not enable it.
- **No runtime attribution in the metric pipeline.** Neither `kubeletstats` nor
  `k8sattributes` surfaces `runtimeClassName`, so **from metrics alone you cannot
  tell a sandboxed pod from a normal one**. Join via the CR watch stream, or
  stamp a pod label in the `SandboxTemplate` and extract it with `k8sattributes`.

---

## Step 10 — Lifecycle: suspend, resume, expire

Hibernation is the cost lever. Flip `operatingMode`:

```bash
kubectl patch sandbox demo-agent --type=merge \
  -p '{"spec":{"operatingMode":"Suspended"}}'
kubectl get sandbox demo-agent -o jsonpath='{.status.conditions}' | jq
```

Observed transitions:

| Trigger | `Ready` | `Suspended` | reason |
|---|---|---|---|
| create → pod running | `True` | — | `DependenciesReady` |
| `operatingMode: Suspended` | `False` | `True` | `SandboxSuspended` / `PodTerminated` |
| back to `Running` | `True` | **`True` (stale)** | `DependenciesReady` / `PodTerminated` |

> ⚠️ **The `Suspended` condition is never cleared on resume.** After a
> suspend/resume cycle the sandbox reports `Ready=True` *and*
> `Suspended=True (PodTerminated)` simultaneously, indefinitely — confirmed on
> v0.5.2 across a 30-second settle and a second full cycle. Anything that alerts
> on `Suspended=True`, or counts suspended sandboxes from it, produces false
> positives forever after the first suspend. **Gate on `Ready`, or on the absence
> of a Pod — not on `Suspended`.**

> ⚠️ **Suspend is not checkpoint/restore.** It **deletes the pod outright**
> (`kubectl get pod` → NotFound) and recreates it on resume. Measured resume with
> the real OpenClaw image, on a node that already has the image cached:
> new pod in **2 s**, pod Ready at **8 s**, gateway actually serving at **22 s** —
> a full cold start. On a node without the image, add the ~2.5-minute pull.
> Any "suspend idle agent sessions to save money" strategy must budget that on
> wake, and any in-memory state in the agent is gone.

TTL is the other lever — `shutdownTime` (RFC3339) with `shutdownPolicy`
(`Retain` / `Delete` / `DeleteForeground`). The `ttl-victim` sandbox in the
lifecycle driver exists to produce `agent_sandboxes{expired="true"}`, which is
your **reclamation-leak** alert: expired but still alive means something isn't
collecting the garbage.

---

## Step 11 — Operating guidance

**Isolation.** Always pair sandboxes that run untrusted code with
`runtimeClassName: gvisor` (or Kata). A plain `runc` Sandbox shares the host
kernel and gives you nothing beyond a nicer API. Read the upstream
[threat model](https://github.com/kubernetes-sigs/agent-sandbox/blob/main/docs/security/threat_model.md):
it documents a **reserved-label spoofing** risk where a tenant setting
`agents.x-k8s.io/sandbox-name-hash` in their own pod template could pull another
tenant's traffic. The controller filters those keys and re-asserts the hash — so
**keep the controller patched and don't downgrade**. Your isolation depends on
that filtering.

**Network.** Default to `networkPolicyManagement: Managed` with default-deny plus
an explicit egress allow-list. The upstream aider example allows DNS and `:443`
only. This is what stops a rogue agent exfiltrating your data.

**Cost.** Set requests/limits on every `podTemplate` container. Use
`shutdownTime` + `shutdownPolicy: Delete` for reclamation. Size `SandboxWarmPool`
`replicas` as a deliberate latency-versus-idle-cost trade — and then **verify the
pool is actually being hit** (§9a), because a pool with a 0% hit rate is pure
cost.

**What to alert on:**

| Alert on | Not on |
|---|---|
| `workqueue_depth` sustained > 0 | `controller_runtime_reconcile_errors_total` (§9c) |
| `agent_sandboxes{ready_condition="false"}` sustained | raw restart counts of sandbox pods |
| `agent_sandboxes{expired="true"}` (reclamation leak) | — |
| warm-pool hit rate dropping (§9a) | — |
| `controller_runtime_webhook_requests_total{code!="200"}` | — |

**Upgrades.** Use version-pinned release manifests. Two API versions are served
(`v1alpha1`, `v1beta1`) with a conversion webhook between them — test conversion
before bumping, and watch that webhook's metrics during the rollout.

**Semantic conventions.** `gen_ai.*` versus OpenInference **does not apply here**.
`agent-sandbox` is infrastructure: it has no notion of models, tokens or prompts,
emits no GenAI telemetry, and defines no convention of its own. That question
matters exactly one layer up, if the workload *inside* the sandbox is an LLM
agent. When it is: prefer **`gen_ai.*`** (OTel semconv), and stamp platform
attributes on those spans —
`agentsandbox.sandbox.name`, `agentsandbox.launch_type`, `agentsandbox.template` —
so the agent's traces can be joined back to the sandbox that ran them.

---

## Step 12 — Cleanup

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

Deleting `gvisor.yaml` removes the RuntimeClass and the installer DaemonSet, but
does **not** uninstall `runsc` from the nodes or revert the containerd config.
On a disposable cluster, delete the cluster.
