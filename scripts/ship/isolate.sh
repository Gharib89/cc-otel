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

n=${1:?usage: scripts/ship/isolate.sh <issue> <type> <slug>}
type=${2:?usage: scripts/ship/isolate.sh <issue> <type> <slug>}
slug=${3:?usage: scripts/ship/isolate.sh <issue> <type> <slug>}

# Resolve the MAIN checkout even when invoked from inside another worktree
# (--git-common-dir points at the primary .git regardless).
root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
cd "$root"
branch="$type/$slug-$n"
wt="$(dirname "$root")/$(basename "$root")-$n"

git fetch origin main >&2

if git show-ref --verify --quiet "refs/heads/$branch" || [ -e "$wt" ]; then
  printf '{"error":"branch %s or worktree %s already exists"}\n' "$branch" "$wt"
  exit 1
fi

git worktree add "$wt" -b "$branch" origin/main >&2

copied="[]"
files=""
for f in .env .env.interim .env.prod; do
  if [ -f "$f" ]; then
    cp "$f" "$wt/$f"
    files="$files${files:+,}\"$f\""
  fi
done
[ -n "$files" ] && copied="[$files]"

printf '{"worktree":"%s","branch":"%s","env_files":%s}\n' "$wt" "$branch" "$copied"
