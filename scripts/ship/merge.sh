#!/usr/bin/env bash
# ship phase-9 merge mechanics — run ONLY after the human said "merge".
# Implements CLAUDE.md's land-and-clean ritual end to end: env files out of the
# worktree, squash-merge, verify merged, verify the issue closed, explicit remote
# branch delete (gh's --delete-branch fails its local step while main is checked
# out), worktree + local branch removal, ff-only pull.
#
# stdout: {"merged": bool, "issue_closed": bool, "remote_branch_deleted": bool,
#          "worktree_removed": bool, "main_updated": bool}
# exit:   0 all steps done · 1 a step failed (JSON shows which)
#
# Usage: scripts/ship/merge.sh <pr-number> <issue-number> [--worktree <path>]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

pr=${1:?usage: scripts/ship/merge.sh <pr> <issue> [--worktree <path>]}
issue=${2:?usage: scripts/ship/merge.sh <pr> <issue> [--worktree <path>]}
wt=""
[ "${3:-}" = "--worktree" ] && wt=${4:?--worktree needs a path}

# NB: intentionally no `set -e` — the cleanup steps below use explicit
# `|| finish 1` / `|| true`, and `git ls-remote --exit-code` returning non-zero
# is a *success* signal (branch gone); `-e` would abort the ritual mid-clean.
# The one command whose failure must halt is the cd, guarded here.
root=$(git rev-parse --show-toplevel) || { ship_emit error "$(ship_qstr "not a git repo")"; exit 1; }
cd "$root" || { ship_emit error "$(ship_qstr "cd to repo root failed")"; exit 1; }

merged=false issue_closed=false remote_deleted=false wt_removed=false main_updated=false

finish() {
  ship_emit merged "$merged" issue_closed "$issue_closed" remote_branch_deleted "$remote_deleted" \
    worktree_removed "$wt_removed" main_updated "$main_updated"
  exit "$1"
}

branch=$(gh pr view "$pr" --json headRefName --jq .headRefName) || finish 1

# Copy gitignored env files out of the worktree before it is destroyed.
if [ -n "$wt" ]; then
  for f in "${SHIP_ENV_FILES[@]}"; do
    [ -f "$wt/$f" ] && [ ! -f "$root/$f" ] && cp "$wt/$f" "$root/$f"
  done
fi

gh pr merge "$pr" --squash >&2 || finish 1

# Re-verify the merge actually took — don't assume the command did.
for _ in 1 2 3; do
  state=$(gh pr view "$pr" --json state --jq .state)
  [ "$state" = "MERGED" ] && merged=true && break
  sleep 2
done
[ "$merged" = true ] || { echo "PR #$pr did not reach MERGED" >&2; finish 1; }

# `Closes #<issue>` in the squash body should auto-close; verify, else close.
for _ in 1 2 3; do
  istate=$(gh issue view "$issue" --json state --jq .state)
  [ "$istate" = "CLOSED" ] && issue_closed=true && break
  sleep 2
done
if [ "$issue_closed" = false ]; then
  gh issue close "$issue" --comment "Closed by PR #$pr (auto-close did not fire)." >&2 \
    && issue_closed=true
fi

git push origin --delete "$branch" >&2 2>/dev/null || true
# --exit-code: 0 = ref still present, 2 = no matching ref (deleted), other = a
# transient/auth error. Only exit 2 proves deletion — don't let a network blip
# read as success.
git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
[ $? -eq 2 ] && remote_deleted=true

if [ -n "$wt" ] && [ -e "$wt" ]; then
  git worktree remove --force "$wt" >&2 && wt_removed=true
else
  wt_removed=true
fi
# A squash-merged branch is not an ancestor of main: force delete.
git branch -D "$branch" >&2 2>/dev/null || true

if [ "$(git branch --show-current)" = "main" ]; then
  # The shared main checkout races a concurrent git status (core.fscache takes
  # index.lock to write back the stat cache), which can leave a transient lock
  # that fails the ff-pull. The racing status finishes in <1s, so retry with
  # backoff clears it without touching the filesystem. Never auto-delete the
  # lock — a 0-byte lock is only safe to remove with no git process running,
  # which this script can't prove. Exhausted retries degrade to main_updated:false.
  for attempt in 1 2 3; do
    git pull --ff-only >&2 && main_updated=true && break
    [ "$attempt" -lt 3 ] && sleep "$attempt"
  done
else
  echo "main checkout is not on main — skipping pull" >&2
fi

[ "$merged" = true ] && [ "$issue_closed" = true ] && [ "$remote_deleted" = true ] \
  && [ "$wt_removed" = true ] && finish 0
finish 1
