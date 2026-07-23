#!/usr/bin/env bash
# ship phase-1 claim ops: the assignee IS the claim (reference/cc-otel.md).
# Idempotent both ways.
#
# stdout: {"issue": N, "claim": "added" | "released"}
# exit:   0 ok · 2 gh failure
#
# Usage: scripts/ship/claim.sh <issue-number> [--release]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

n=${1:?usage: scripts/ship/claim.sh <issue> [--release]}

fail() { ship_emit issue "$n" error "$(ship_qstr "$1")"; exit 2; }

if [ "${2:-}" = "--release" ]; then
  gh issue edit "$n" --remove-assignee @me >/dev/null || fail "gh issue edit --remove-assignee failed"
  ship_emit issue "$n" claim "$(ship_qstr released)"
else
  gh issue edit "$n" --add-assignee @me >/dev/null || fail "gh issue edit --add-assignee failed"
  ship_emit issue "$n" claim "$(ship_qstr added)"
fi
