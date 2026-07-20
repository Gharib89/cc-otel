#!/usr/bin/env bash
# ship phase-0 pre-flight: is <issue> actionable, or already in flight/shipped?
#
# Checks, in order: issue state, any non-closed PR whose head branch ends in
# `-<issue>` (the repo's `<type>/<slug>-<issue>` convention), and any remote
# branch matching the same suffix. First hit wins.
#
# stdout: one JSON object {"actionable": bool, "reason": "...", "assignees": [...]}
# exit:   0 actionable · 1 not actionable · 2 gh/tooling failure
#
# Usage: scripts/ship/preflight.sh <issue-number>
set -euo pipefail

n=${1:?usage: scripts/ship/preflight.sh <issue-number>}

emit() { # emit <true|false> <reason>
  printf '{"actionable":%s,"reason":"%s","assignees":%s}\n' "$1" "$2" "${assignees:-[]}"
}

state=$(gh issue view "$n" --json state --jq .state) \
  || { emit false "gh issue view $n failed"; exit 2; }
assignees=$(gh issue view "$n" --json assignees --jq '[.assignees[].login]')

if [ "$state" != "OPEN" ]; then
  emit false "issue #$n is $state"
  exit 1
fi

# A non-closed PR on a `…-<issue>` branch means in flight (OPEN) or shipped (MERGED).
pr=$(gh pr list --state all --json number,state,headRefName \
  --jq "[.[] | select(.headRefName | test(\"-$n\$\")) | select(.state != \"CLOSED\")] | first | if . then \"PR #\(.number) (\(.state)) on \(.headRefName)\" else \"\" end")
if [ -n "$pr" ]; then
  emit false "$pr already exists"
  exit 1
fi

branch=$(git ls-remote --heads origin | awk '{print $2}' | grep -E -- "-$n\$" | head -1 || true)
if [ -n "$branch" ]; then
  emit false "remote branch ${branch#refs/heads/} already exists"
  exit 1
fi

emit true "open, no PR, no branch"
