#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-shot installer for the agent-sandbox episode stack.
#
#   ./deploy/deploy.sh
#
# Installs, in dependency order:
#   1. OpenTelemetry Operator          (self-signed webhook certs, no cert-manager)
#   2. Dynatrace Operator + DynaKube   (ActiveGate only — k8s monitoring)
#   3. gVisor (runsc) RuntimeClass + node installer DaemonSet
#   4. agent-sandbox controller v0.5.2 (+ extensions: Template/WarmPool/Claim)
#   5. OTel Collectors                 (gateway Deployment + node DaemonSet)
#   6. The demo Sandbox                (an agent running under gVisor)
#
# TUTORIAL.md walks through every one of these by hand, with the explanation.
# This script is the shortcut for people who already know why.
# ---------------------------------------------------------------------------
set -euo pipefail

: "${DT_API_URL:?set DT_API_URL, e.g. https://<your-tenant>.live.dynatrace.com/api}"
: "${DT_OPERATOR_TOKEN:?set DT_OPERATOR_TOKEN (Dynatrace API token)}"
: "${DT_INGEST_TOKEN:?set DT_INGEST_TOKEN (data-ingest token)}"

# OpenClaw needs at least one model-provider key. The gateway binds to a
# non-loopback address (so the Sandbox Service can reach it), which makes token
# auth mandatory.
: "${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY (or edit deploy.sh for GEMINI/OPENAI/OPENROUTER)}"
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-$(head -c 24 /dev/urandom | base64 | tr -d '/+=')}"

AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-v0.5.2}"
OTEL_OPERATOR_VERSION="${OTEL_OPERATOR_VERSION:-0.120.0}"  # chart version; app version is 0.156.0
DT_OPERATOR_VERSION="${DT_OPERATOR_VERSION:-1.9.0}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# --- 1. OpenTelemetry Operator ---------------------------------------------
say "OpenTelemetry Operator ${OTEL_OPERATOR_VERSION}"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null
helm repo update >/dev/null
helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
  -n opentelemetry-operator-system --create-namespace \
  --version "${OTEL_OPERATOR_VERSION}" \
  --set "manager.image.repository=ghcr.io/open-telemetry/opentelemetry-operator/opentelemetry-operator" \
  --set admissionWebhooks.certManager.enabled=false \
  --set admissionWebhooks.autoGenerateCert.enabled=true \
  --wait

# --- 2. Dynatrace ------------------------------------------------------------
say "Dynatrace Operator ${DT_OPERATOR_VERSION} + DynaKube (ActiveGate only)"
kubectl create namespace dynatrace --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic agent-sandbox-demo -n dynatrace \
  --from-literal=apiToken="${DT_OPERATOR_TOKEN}" \
  --from-literal=dataIngestToken="${DT_INGEST_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

helm repo add dynatrace https://raw.githubusercontent.com/Dynatrace/dynatrace-operator/main/config/helm/repos/stable >/dev/null
helm repo update >/dev/null
helm upgrade --install dynatrace-operator dynatrace/dynatrace-operator \
  -n dynatrace --version "${DT_OPERATOR_VERSION}" --set installCRD=true --wait

sed "s#https://<your-tenant>.live.dynatrace.com/api#${DT_API_URL}#" \
  "${HERE}/dynatrace/dynakube.yaml" | kubectl apply -f -

# --- 3. gVisor ---------------------------------------------------------------
say "gVisor (runsc) RuntimeClass + node installer"
kubectl apply -f "${HERE}/gvisor/gvisor.yaml"
kubectl -n kube-system rollout status ds/gvisor-installer --timeout=10m

# --- 4. agent-sandbox --------------------------------------------------------
say "agent-sandbox ${AGENT_SANDBOX_VERSION} (controller + extensions)"
kubectl apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/sandbox-with-extensions.yaml"
kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller --timeout=5m

# --- 5. Collectors -----------------------------------------------------------
say "OpenTelemetry Collectors (gateway + node agent)"
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic dynatrace-otlp -n observability \
  --from-literal=dataIngestToken="${DT_INGEST_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

for f in "${HERE}/collectors/otel-gateway.yaml" "${HERE}/collectors/otel-node-agent.yaml"; do
  sed "s#https://<your-tenant>.live.dynatrace.com/api#${DT_API_URL}#" "$f" | kubectl apply -f -
done

# --- 6. Demo sandbox ---------------------------------------------------------
say "Demo agent Sandbox (OpenClaw under gVisor)"
kubectl create secret generic openclaw-secrets -n default \
  --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  --from-literal=OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${HERE}/agent-sandbox/demo-sandbox.yaml"

# First pull of ghcr.io/openclaw/openclaw:slim is ~324 MB — allow a few minutes
# on a node that has never seen it.
kubectl wait --for=condition=Ready sandbox/demo-agent --timeout=10m || true

say "Done. Next: kubectl get sandbox,sandboxclaim,sandboxwarmpool -A"
echo "    Drive the full lifecycle:  kubectl apply -f ${HERE}/agent-sandbox/lifecycle-driver.yaml"
echo "    Then follow TUTORIAL.md from Step 7 to read the telemetry."
