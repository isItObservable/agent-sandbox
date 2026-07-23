# `deploy/` — everything you apply

Apply order matters. `./deploy.sh` does it for you; this is the map if you'd
rather go by hand, following [`../TUTORIAL.md`](../TUTORIAL.md).

| # | Path | What it is | Tutorial step |
|---|------|------------|---------------|
| 1 | *(helm)* | OpenTelemetry Operator — provides the `OpenTelemetryCollector` CRD | [2](../TUTORIAL.md#step-2--opentelemetry-operator) |
| 2 | `gvisor/gvisor.yaml` | `gvisor` RuntimeClass + privileged node-installer DaemonSet (`runsc` + containerd config) | [3](../TUTORIAL.md#step-3--gvisor-the-kernel-boundary) |
| 3 | `dynatrace/dynakube.yaml` | ActiveGate-only DynaKube. **No OneAgent** — not full-stack | [4](../TUTORIAL.md#step-4--dynatrace-operator--dynakube) |
| 4 | *(release URL)* | `agent-sandbox` v0.5.2 controller + 4 CRDs | [5](../TUTORIAL.md#step-5--the-agent-sandbox-controller) |
| 5 | `agent-sandbox/demo-sandbox.yaml` | One hand-written `Sandbox` running OpenClaw under gVisor (+ its ConfigMap) | [6](../TUTORIAL.md#step-6--your-first-sandbox-and-proving-the-boundary) |
| 6 | `agent-sandbox/lifecycle-driver.yaml` | `SandboxTemplate` + `SandboxWarmPool` + two `SandboxClaim`s + a TTL sandbox | [7](../TUTORIAL.md#step-7--templates-warm-pools-and-claims) |
| 6b | `agent-sandbox/openclaw-pool.yaml` | `SandboxTemplate` + `SandboxWarmPool` + the good/trap claim pair, all on the real OpenClaw image | [7](../TUTORIAL.md#step-7--templates-warm-pools-and-claims) |
| 7 | `collectors/otel-gateway.yaml` | Gateway Collector — `prometheus`, `k8s_cluster`, `k8sobjects`, `otlp` | [8](../TUTORIAL.md#step-8--the-opentelemetry-collectors) |
| 8 | `collectors/otel-node-agent.yaml` | Node Collector (DaemonSet) — `kubeletstats`, `filelog` | [8](../TUTORIAL.md#step-8--the-opentelemetry-collectors) |
| — | `dashboards/` | Dynatrace dashboard for the sandbox fleet | [9](../TUTORIAL.md#step-9--read-the-telemetry-the-four-traps) |
| — | `agent-sandbox/openclaw-secret.example.yaml` | OpenClaw model-provider key + gateway token template. **Never commit real keys.** | [6](../TUTORIAL.md#step-6--your-first-sandbox-and-proving-the-boundary) |
| — | `dynatrace/dynatrace-secret.example.yaml` | Token secret template. **Never commit real tokens.** | [4](../TUTORIAL.md#step-4--dynatrace-operator--dynakube) |

## Backend

Every manifest that talks to a backend uses the placeholder
`https://<your-tenant>.live.dynatrace.com/api`. `deploy.sh` substitutes
`${DT_API_URL}` on apply; by hand, `sed` it yourself:

```bash
sed "s#https://<your-tenant>.live.dynatrace.com/api#${DT_API_URL}#" <file> | kubectl apply -f -
```

Not using Dynatrace? Swap the `otlphttp/dynatrace` exporter in both Collectors for
any OTLP endpoint and skip `dynatrace/` entirely. You lose the ActiveGate's
cluster-state metrics; the gateway's `k8s_cluster` receiver covers most of that.

## Gotchas already fixed in these files

So a rebuild doesn't rediscover them. Full context in
[`../OBSERVABILITY.md`](../OBSERVABILITY.md) §10.

- **`kubeletstats` cannot run in a Deployment** — node *names* don't resolve in
  cluster DNS. It is a DaemonSet using `status.hostIP`.
- **The CRD API group is split** — `sandboxes` is in `agents.x-k8s.io`; the other
  three are in `extensions.agents.x-k8s.io`. Wrong group = silent RBAC
  `forbidden` on the watch, with the Collector still reporting `Running`.
- **`k8s_cluster` needs `autoscaling` RBAC** even with zero HPAs, or it log-spams
  forever.
- **No heredocs in `gvisor.yaml`** — a heredoc terminator at column 0 ends the
  YAML block scalar. Uses indented `printf` instead.
- **`debian:12-slim` has no `curl`** — the gVisor installer installs it first.
- **The ActiveGate image is pinned to public ECR** — the tenant-tagged image 404s.
