#!/usr/bin/env bash
# ship CI wait: conflict check first (a conflicted PR has no merge ref,
# so its checks sit pending forever — never wait on it), then block until every
# check completes.
#
# stdout: {"status": "green" | "no-checks" | "conflict" | "checks-failed"
#                    | "timeout" | "tooling", "failing": [names]}
# exit:   0 green/no-checks · 1 conflict or a check failed · 2 timeout/tooling
#
# Usage: scripts/ship/ci-wait.sh <pr-number> [--timeout <seconds>]
set -uo pipefail
# No `set -e` here, so guard the source: a failed load must still emit the
# JSON verdict contract (a tooling failure), not "command not found" to stdout.
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" \
  || { printf '{"status":"tooling","failing":[]}\n'; exit 2; }

pr=${1:?usage: scripts/ship/ci-wait.sh <pr-number> [--timeout <seconds>]}
limit=1800
[ "${2:-}" = "--timeout" ] && limit=${3:?--timeout needs seconds}

emit() { ship_emit status "$1" failing @"${2:-[]}"; }

m=$(gh pr view "$pr" --json mergeable,mergeStateStatus \
  --jq '"\(.mergeable) \(.mergeStateStatus)"') || { emit tooling; exit 2; }
case $m in
  CONFLICTING*|*DIRTY)
    emit conflict
    echo "PR #$pr conflicts with the base branch: rebase, fix, re-run the local gate, push." >&2
    exit 1 ;;
esac

# --watch blocks until all checks complete; non-zero when any failed. A
# path-filtered repo can legitimately report no checks at all for a docs-only PR.
watch_log=$(mktemp)
if have_timeout=$(command -v timeout); then
  "$have_timeout" --foreground "$limit" gh pr checks "$pr" --watch --interval 30 >"$watch_log" 2>&1
else
  gh pr checks "$pr" --watch --interval 30 >"$watch_log" 2>&1
fi
rc=$?

if grep -qi 'no checks reported' "$watch_log"; then
  emit no-checks; rm -f "$watch_log"; exit 0
fi
if [ "$rc" = 124 ]; then
  emit timeout; rm -f "$watch_log"; exit 2
fi
rm -f "$watch_log"

if [ "$rc" -ne 0 ]; then
  # --watch's non-zero could be a check failure OR a tooling/auth blip; if this
  # follow-up read also fails, don't let its stderr pollute the failing list —
  # report tooling instead.
  failing=$(gh pr checks "$pr" --json name,bucket \
    --jq '[.[] | select(.bucket == "fail") | .name]') || { emit tooling; exit 2; }
  emit checks-failed "$failing"
  exit 1
fi

emit green
