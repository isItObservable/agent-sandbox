# Dashboards

The Dynatrace dashboard for this episode. Import the JSON in this directory into
your tenant (**Dashboards → Upload**), or rebuild it from the tile list below.

Every source metric is confirmed present with the pipeline in
[`../collectors/`](../collectors/) — see
[`../../OBSERVABILITY.md`](../../OBSERVABILITY.md) for how each one was verified.

## Tiles, in priority order

| # | Tile | Source | Why |
|---|------|--------|-----|
| 1 | **Warm-pool hit rate** ⭐ | `agent_sandboxes` by `launch_type`, `owned_by="SandboxClaim"` | **The headline.** Pinned at `cold` means your pool is decorative — see OBSERVABILITY.md §2 |
| 2 | Sandbox inventory | `agent_sandboxes` by `namespace`, `sandbox_template`, `ready_condition` | What exists, right now |
| 3 | Not-ready sandboxes | `agent_sandboxes{ready_condition="false"}` | Alert if sustained |
| 4 | Expired but alive | `agent_sandboxes{expired="true"}` | A reclamation leak |
| 5 | Controller saturation | `workqueue_depth`, `workqueue_queue_duration_seconds` per controller | The real "keeping up?" signal |
| 6 | Reconcile latency | `controller_runtime_reconcile_time_seconds` p50/p95 by controller | |
| 7 | Per-sandbox resources | `k8s.pod.cpu.usage`, `k8s.pod.memory.working_set` | From `kubeletstats`, **never** from inside the sandbox (§6) |
| 8 | Lifecycle event stream | logs on `agentsandbox.watch.type`, `agentsandbox.ready_reason` | The workaround for zero K8s Events (§3) |
| 9 | Conversion webhook health | `controller_runtime_webhook_requests_total` by `code` | A failing `/convert` breaks every CRD API call |

## The headline query

```dql
timeseries sb = avg(agent_sandboxes), by:{launch_type}, filter: owned_by == "SandboxClaim"
```

Render as `warm / (warm + cold)`.

## ⚠️ What NOT to put on this dashboard

**`controller_runtime_reconcile_errors_total{controller="sandbox"}`.**

It has a permanent non-zero floor from a benign optimistic-concurrency race that
self-heals on requeue. Charting it makes a healthy cluster look broken; alerting
on it pages you forever. Use `workqueue_depth` instead. Details in
[`../../OBSERVABILITY.md`](../../OBSERVABILITY.md) §4b.
