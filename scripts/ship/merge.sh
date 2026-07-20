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

pr=${1:?usage: scripts/ship/merge.sh <pr> <issue> [--worktree <path>]}
issue=${2:?usage: scripts/ship/merge.sh <pr> <issue> [--worktree <path>]}
wt=""
[ "${3:-}" = "--worktree" ] && wt=${4:?--worktree needs a path}

# NB: intentionally no `set -e` — the cleanup steps below use explicit
# `|| finish 1` / `|| true`, and `git ls-remote --exit-code` returning non-zero
# is a *success* signal (branch gone); `-e` would abort the ritual mid-clean.
# The one command whose failure must halt is the cd, guarded here.
root=$(git rev-parse --show-toplevel) || { echo '{"error":"not a git repo"}'; exit 1; }
cd "$root" || { echo '{"error":"cd to repo root failed"}'; exit 1; }

merged=false issue_closed=false remote_deleted=false wt_removed=false main_updated=false

finish() {
  printf '{"merged":%s,"issue_closed":%s,"remote_branch_deleted":%s,"worktree_removed":%s,"main_updated":%s}\n' \
    "$merged" "$issue_closed" "$remote_deleted" "$wt_removed" "$main_updated"
  exit "$1"
}

branch=$(gh pr view "$pr" --json headRefName --jq .headRefName) || finish 1

# Copy gitignored env files out of the worktree before it is destroyed.
if [ -n "$wt" ]; then
  for f in .env .env.interim .env.prod; do
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
git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 || remote_deleted=true

if [ -n "$wt" ] && [ -e "$wt" ]; then
  git worktree remove --force "$wt" >&2 && wt_removed=true
else
  wt_removed=true
fi
# A squash-merged branch is not an ancestor of main: force delete.
git branch -D "$branch" >&2 2>/dev/null || true

if [ "$(git branch --show-current)" = "main" ]; then
  git pull --ff-only >&2 && main_updated=true
else
  echo "main checkout is not on main — skipping pull" >&2
fi

[ "$merged" = true ] && [ "$issue_closed" = true ] && [ "$remote_deleted" = true ] \
  && [ "$wt_removed" = true ] && finish 0
finish 1
