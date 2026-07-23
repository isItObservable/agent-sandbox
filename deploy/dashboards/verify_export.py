#!/usr/bin/env python3
"""Verify a Dynatrace dashboard JSON is safe to publish and safe to import.

Catches the four ways a dashboard export goes wrong on its way into a public
repo. Every check here corresponds to a defect that actually shipped while this
episode was being built, not a hypothetical.

    python3 verify_export.py agent-sandbox-fleet.dashboard.json

Exit 0 = publishable. Exit 1 = do not commit.
"""
import json
import os
import re
import sys

# Fields that only exist on a *downloaded* dashboard (`dtctl get dashboard`).
# Their presence means someone published the .deployed.json instead of the
# authoring copy. `id` is the dangerous one: `dtctl apply` on a file carrying an
# id UPDATES that live dashboard instead of creating a new one, so a reader
# importing the file mutates the author's tenant.
TENANT_FIELDS = ["id", "owner", "version", "modificationInfo", "isPrivate"]

# Internal infrastructure names that must never reach a public repo: your real
# cluster names, tenant ids, management-cluster names. Supply your own, since
# they are site-specific — and do not hardcode them here, or the denylist itself
# becomes the leak.
#
#     export DASHBOARD_INTERNAL_NAMES="prod-cluster-01,abc12345,mgmt-prod"
INTERNAL = [s.strip() for s in os.environ.get("DASHBOARD_INTERNAL_NAMES", "").split(",") if s.strip()]

# Checked unconditionally: a real Dynatrace tenant id or API token is a leak in
# any repo, and needs no site-specific configuration to recognise.
TENANT_PATTERNS = [
    (r"dt0c01\.[A-Z0-9]{24}", "Dynatrace API token"),
    (r"https://(?!<)[a-z]{3}[0-9]{5}\.(live|apps)\.dynatrace\.com", "live Dynatrace tenant URL"),
]

# The placeholder the README tells readers to search for. If the README and the
# JSON disagree, readers grep for a string that isn't there, import unchanged,
# and get blank tiles on every scoped query — a silent failure.
PLACEHOLDER = "agent-sandbox-demo"


def main(path):
    raw = open(path, encoding="utf-8").read()
    doc = json.loads(raw)
    errors, warnings = [], []

    leaked = [f for f in TENANT_FIELDS if f in doc]
    if leaked:
        errors.append(
            "tenant export metadata present: %s — this looks like .deployed.json, "
            "not the authoring copy. `id` in particular makes `dtctl apply` mutate "
            "the source dashboard on import." % ", ".join(leaked)
        )

    for name in INTERNAL:
        n = raw.count(name)
        if n:
            errors.append("internal name %r appears %d time(s)" % (name, n))
    if not INTERNAL:
        warnings.append(
            "DASHBOARD_INTERNAL_NAMES is unset — the internal-name check is a no-op. "
            "Set it to your own cluster/tenant names before trusting this run."
        )

    for pattern, label in TENANT_PATTERNS:
        hits = re.findall(pattern, raw)
        if hits:
            errors.append("%s present (%d match(es))" % (label, len(hits)))

    if PLACEHOLDER not in raw:
        warnings.append(
            "placeholder %r not found — confirm the README's "
            "'change this to your cluster name' instruction still matches" % PLACEHOLDER
        )

    content = doc.get("content")
    if isinstance(content, str):
        content = json.loads(content)
    tiles = (content or {}).get("tiles", {})
    layouts = (content or {}).get("layouts", {})
    if set(tiles) != set(layouts):
        errors.append(
            "tile/layout id mismatch — tiles only: %s | layouts only: %s"
            % (sorted(set(tiles) - set(layouts)), sorted(set(layouts) - set(tiles)))
        )

    data_tiles = [t for t in tiles.values() if t.get("type") == "data"]
    unscoped = [
        t.get("title")
        for t in data_tiles
        if "k8s.cluster.name" not in t.get("query", "")
        and re.search(r"\b(workqueue_|controller_runtime_)", t.get("query", ""))
    ]
    if unscoped:
        errors.append(
            "controller-runtime tiles not scoped by k8s.cluster.name (these metric "
            "names collide across clusters in one tenant): %s" % unscoped
        )

    print("%s: %d tiles (%d data), %d layouts"
          % (path, len(tiles), len(data_tiles), len(layouts)))
    for w in warnings:
        print("  WARN  %s" % w)
    for e in errors:
        print("  FAIL  %s" % e)
    if errors:
        print("\nNOT publishable.")
        return 1
    print("\nOK — safe to publish and safe for a reader to import.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
