#!/usr/bin/env bash
# ship phase-1 claim ops: the assignee IS the claim (reference/cc-otel.md).
# Idempotent both ways.
#
# stdout: {"issue": N, "claim": "added" | "released"}
# exit:   0 ok · 2 gh failure
#
# Usage: scripts/ship/claim.sh <issue-number> [--release]
set -euo pipefail

n=${1:?usage: scripts/ship/claim.sh <issue> [--release]}

fail() { printf '{"issue":%s,"error":"%s"}\n' "$n" "$1"; exit 2; }

if [ "${2:-}" = "--release" ]; then
  gh issue edit "$n" --remove-assignee @me >/dev/null || fail "gh issue edit --remove-assignee failed"
  printf '{"issue":%s,"claim":"released"}\n' "$n"
else
  gh issue edit "$n" --add-assignee @me >/dev/null || fail "gh issue edit --add-assignee failed"
  printf '{"issue":%s,"claim":"added"}\n' "$n"
fi
