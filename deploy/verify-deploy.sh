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

# Fail loudly if the inputs are not where we think. Run this from a copy of
# deploy/ without the repo root and `set -e` aborts mid-check with NO output and
# no visible reason — a guard that silently produces nothing is the same hazard
# as a guard that cannot fail.
_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for required in "${_here}/deploy.sh" "${_here}/../TUTORIAL.md"; do
  [ -f "$required" ] || { echo "verify-deploy: missing $required — run this from inside the repo" >&2; exit 2; }
done

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

echo "4. Every environment-specific address is substituted, not hard-coded"
# Several manifests carry placeholder addresses that deploy.sh rewrites from
# environment variables. Do NOT pattern-match the sed expressions -- RUN the
# line deploy.sh actually runs, with unmistakable test values, and look at the
# output. (Matching the source text is how the first version of this check
# produced a false failure: the patterns in deploy.sh are escaped, `10\.20\.30\.10`.)
#
# And do not check one known placeholder: this check originally knew only about
# the model address, and a later pass that replaced the lab's real addresses
# with documentation ones introduced THREE more -- the WebUI Service IP, the
# allowedOrigins entry, and the ingress CIDR -- none of which deploy.sh
# substituted. So derive every placeholder from the file that defines it and
# walk every manifest deploy.sh applies.
OLLAMA_HOST=203.0.113.99    # TEST-NET-3, unmistakable in the output
WEBUI_IP=203.0.113.98
LAN_CIDR=203.0.113.0/24

# Derived, never hard-coded -- the published copy of this repo carries
# documentation addresses and the filmed copy carries real ones, and this same
# check has to hold for both.
MODEL_ADDR=$(sed -n 's/^ *- *"\([0-9.]\{7,\}\)".*/\1/p' "${HERE}/agent-sandbox/ollama-endpoint.yaml" | head -1)
WEBUI_ADDR=$(sed -n 's/^ *loadBalancerIP: *\([0-9.]\{7,\}\).*/\1/p' "${HERE}/agent-sandbox/openclaw-ui-service.yaml" | head -1)
LAN_ADDR="${WEBUI_ADDR%.*}.0/24"
[ -n "$MODEL_ADDR" ] || note "could not read the model address out of ollama-endpoint.yaml"
[ -n "$WEBUI_ADDR" ] || note "could not read the WebUI address out of openclaw-ui-service.yaml"

for f in $(grep -oE '\$\{HERE\}/agent-sandbox/[a-z0-9.-]+\.yaml' "${HERE}/deploy.sh" | sed "s#\${HERE}#${HERE}#" | sort -u); do
  base="${f##*/}"
  # Which placeholders does this file actually carry, outside comments?
  carried=""
  for addr in "$MODEL_ADDR" "$WEBUI_ADDR" "$LAN_ADDR"; do
    [ -n "$addr" ] || continue
    grep -vE '^\s*#' "$f" | grep -qF "$addr" && carried="$carried $addr"
  done
  [ -n "$carried" ] || { ok "$base carries no environment-specific address"; continue; }

  cmd=$(grep -E "^ *sed .*${base}|^ *sed -e" "${HERE}/deploy.sh" | grep -A0 -B0 "" | head -1 >/dev/null; \
        awk -v b="$base" '/^ *sed /{buf=$0; while (buf ~ /\\$/) {getline nx; sub(/\\$/,"",buf); buf=buf nx} if (buf ~ b) {sub(/\| *kubectl.*/,"",buf); print buf; exit}}' "${HERE}/deploy.sh")
  [ -n "$cmd" ] && cmd=${cmd//\$\{HERE\}/$HERE}
  if [ -z "$cmd" ]; then
    note "$base carries an environment-specific address ($(echo $carried)) but deploy.sh applies it unsubstituted"
    continue
  fi
  out=$(eval "$cmd") || { note "$base substitution command failed to run"; continue; }
  # Ignore comments: the cilium policy quotes measured results verbatim on purpose.
  live=$(grep -vE '^\s*#' <<<"$out")
  leftover=0
  for addr in $carried; do
    n=$(grep -cF "$addr" <<<"$live" || true); leftover=$((leftover + n))
  done
  if [ "$leftover" -eq 0 ] && grep -qE '203\.0\.113\.(99|98|0)' <<<"$live"; then
    ok "$base rewritten ($(echo $carried))"
  else
    note "$base still ships a placeholder after deploy.sh's sed ($leftover live occurrence(s))"
  fi
done
unset OLLAMA_HOST WEBUI_IP LAN_CIDR

echo "5. Nothing carries an internal ticket reference"
if grep -rniE 'isi[-_ ]?[0-9]{3,4}' "${HERE}" >/dev/null 2>&1; then
  note "internal ticket id found under deploy/:"; grep -rniE 'isi[-_ ]?[0-9]{3,4}' "${HERE}" | head
else ok "clean"; fi

echo
[ "$fail" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "FAILED"; exit 1; }
