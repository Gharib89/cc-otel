#!/usr/bin/env bash
# ship phase-0 isolate: sibling worktree on a fresh branch off origin's default,
# with the gitignored env files copied in (they never get committed).
#
# stdout: {"worktree": "...", "branch": "...", "env_files": [...]}
# exit:   0 created · 1 branch/worktree already exists (run preflight first) · 2 git failure
#
# Usage: scripts/ship/isolate.sh <issue-number> <type> <slug>
#        e.g. scripts/ship/isolate.sh 135 feat script-skills
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

n=${1:?usage: scripts/ship/isolate.sh <issue> <type> <slug>}
type=${2:?usage: scripts/ship/isolate.sh <issue> <type> <slug>}
slug=${3:?usage: scripts/ship/isolate.sh <issue> <type> <slug>}

# Resolve the MAIN checkout even when invoked from inside another worktree
# (--git-common-dir points at the primary .git regardless).
root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
cd "$root"
branch=$(ship_branch "$type" "$slug" "$n")
wt="$(dirname "$root")/$(basename "$root")-$n"

git fetch origin main >&2

if git show-ref --verify --quiet "refs/heads/$branch" || [ -e "$wt" ]; then
  ship_emit error "$(ship_qstr "branch $branch or worktree $wt already exists")"
  exit 1
fi

git worktree add "$wt" -b "$branch" origin/main >&2

copied="[]"
files=""
for f in "${SHIP_ENV_FILES[@]}"; do
  if [ -f "$f" ]; then
    cp "$f" "$wt/$f"
    files="$files${files:+,}$(ship_qstr "$f")"
  fi
done
[ -n "$files" ] && copied="[$files]"

ship_emit worktree "$(ship_qstr "$wt")" branch "$(ship_qstr "$branch")" env_files "$copied"
