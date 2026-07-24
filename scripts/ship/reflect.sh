#!/usr/bin/env bash
# ship PR-reflect: comment the PR link on the issue so a scheduled run
# won't re-pick it.
#
# stdout: {"issue": N, "reflected": "<pr-url>"}
# exit:   0 ok · 2 gh failure
#
# Usage: scripts/ship/reflect.sh <issue-number> <pr-url>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

n=${1:?usage: scripts/ship/reflect.sh <issue> <pr-url>}
url=${2:?usage: scripts/ship/reflect.sh <issue> <pr-url>}

gh issue comment "$n" --body "PR: $url" >/dev/null \
  || { ship_emit issue @"$n" error "gh issue comment failed"; exit 2; }
ship_emit issue @"$n" reflected "$url"
