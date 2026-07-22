#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Does deploy.sh actually produce what the manifests ask for?
#
#   ./deploy/verify-deploy.sh
#
# WHY THIS EXISTS. Moving the demo from a hosted API key to Ollama renamed the
# Secret key that demo-sandbox.yaml and openclaw-pool.yaml mount. The manifests
# were verified against the LIVE cluster and matched perfectly — but the live
# Secret had been created by hand, so the check compared the manifests against
# a cluster that deploy.sh had never built. deploy.sh still created
# ANTHROPIC_API_KEY. A clean-room install would have failed at
# CreateContainerConfigError, and nothing in the repo said so.
#
# The lesson generalises past this one key: "it matches the running cluster" is
# not the same claim as "the installer produces it". This asserts the second.
#
# No cluster required.
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
note() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fail=1; }
ok()   { printf '  \033[1;32mok\033[0m   %s\n' "$*"; }

echo "1. Secret keys: every secretKeyRef on openclaw-secrets must be created by"
echo "   EVERY path that creates it — the script AND the hand walkthrough."

# Keys the manifests mount out of the openclaw-secrets Secret.
wanted=$(grep -A2 'name: openclaw-secrets' \
           "${HERE}/agent-sandbox/demo-sandbox.yaml" \
           "${HERE}/agent-sandbox/openclaw-pool.yaml" \
         | sed -n 's/.*key: \([A-Z_]*\).*/\1/p' | sort -u)
[ -n "$wanted" ] || note "parsed zero secretKeyRef keys — this check is not testing anything"

# Both install paths must agree with it. TUTORIAL.md is not documentation here,
# it is a second installer that people paste line by line.
for src in "${HERE}/deploy.sh" "${HERE}/../TUTORIAL.md"; do
  name=$(basename "$src")
  created=$(sed -n '/kubectl create secret generic openclaw-secrets/,/OPENCLAW_GATEWAY_TOKEN/p' "$src" \
            | sed -n 's/.*--from-literal=\([A-Z_]*\)=.*/\1/p' | sort -u)
  [ -n "$created" ] || { note "$name: parsed zero --from-literal keys — not testing anything"; continue; }
  for k in $wanted; do
    grep -qx "$k" <<<"$created" && ok "$name creates $k" \
      || note "$name never creates $k, but a manifest mounts it (-> CreateContainerConfigError)"
  done
  for k in $created; do
    grep -qx "$k" <<<"$wanted" || echo "  note $name creates $k, which nothing mounts (harmless)"
  done
done

echo "2. No stale hosted-provider key left behind"
if grep -q 'ANTHROPIC_API_KEY' "${HERE}/deploy.sh"; then
  note "deploy.sh still references ANTHROPIC_API_KEY"
else ok "deploy.sh is off the hosted key"; fi

echo "3. Every manifest deploy.sh applies exists on disk"
# Only the literal ${HERE}/... paths; the remote release URL is not our file.
for f in $(grep -oE '\$\{HERE\}/[a-z0-9./-]+\.yaml' "${HERE}/deploy.sh" | sed "s#\${HERE}#${HERE}#" | sort -u); do
  [ -f "$f" ] && ok "$(basename "$f")" || note "deploy.sh applies $(basename "$f"), which does not exist"
done

echo "4. Model-backend address is substituted, not hard-coded"
# ollama-endpoint.yaml and the netpols carry a placeholder IP that deploy.sh
# rewrites from $OLLAMA_HOST. Don't pattern-match the sed expression — RUN the
# line deploy.sh actually runs, with a distinctive host, and look at the output.
# (Matching the source text is how the first version of this check produced a
# false failure: the pattern in deploy.sh is escaped, `10\.20\.30\.10`.)
OLLAMA_HOST=203.0.113.99   # TEST-NET-3, unmistakable in the output

# Derive the placeholder from the EndpointSlice rather than hard-coding it —
# the published copy of this repo carries documentation addresses, not the ones
# the episode was filmed against, and the check has to hold for both.
PLACEHOLDER=$(sed -n 's/^ *- *"\([0-9.]\{7,\}\)".*/\1/p' "${HERE}/agent-sandbox/ollama-endpoint.yaml" | head -1)
[ -n "$PLACEHOLDER" ] || note "could not read the model address out of ollama-endpoint.yaml"

for f in agent-sandbox/ollama-endpoint.yaml agent-sandbox/openclaw-netpol.yaml agent-sandbox/openclaw-netpol-cilium.yaml; do
  base="${f##*/}"
  grep -qF "$PLACEHOLDER" "${HERE}/$f" || { note "$base does not carry the model address $PLACEHOLDER that deploy.sh targets"; continue; }
  cmd=$(grep -E "^ *sed .*${base}" "${HERE}/deploy.sh" | head -1 | sed 's#| *kubectl.*##')
  [ -n "$cmd" ] && cmd=${cmd//\$\{HERE\}/$HERE}
  if [ -z "$cmd" ]; then note "$base carries a placeholder IP but deploy.sh applies it unsubstituted"; continue; fi
  out=$(eval "$cmd") || { note "$base substitution command failed to run"; continue; }
  # Ignore comments: the cilium policy quotes measured results verbatim on purpose.
  leftover=$(grep -vE '^\s*#' <<<"$out" | grep -cF "$PLACEHOLDER" || true)
  if grep -q '203.0.113.99' <<<"$out" && [ "$leftover" -eq 0 ]; then
    ok "$base rewritten to \$OLLAMA_HOST"
  else
    note "$base still ships the placeholder after deploy.sh's sed ($leftover live occurrence(s))"
  fi
done
unset OLLAMA_HOST

echo "5. Nothing carries an internal ticket reference"
if grep -rniE 'isi[-_ ]?[0-9]{3,4}' "${HERE}" >/dev/null 2>&1; then
  note "internal ticket id found under deploy/:"; grep -rniE 'isi[-_ ]?[0-9]{3,4}' "${HERE}" | head
else ok "clean"; fi

echo
[ "$fail" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "FAILED"; exit 1; }
