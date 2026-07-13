---
name: copilot-pr-review-loop
description: Run an N-round review loop that requests GitHub Copilot code review on a pull request, triages the findings, applies tractable fixes, pushes, and re-requests review. Use when the user asks to iterate Copilot review on a PR, after opening a PR while a `github-webhook-activity` subscription is active, or when the `ship` skill reaches its review-bot phase.
---

# Copilot PR Review Loop

Drive `copilot-pull-request-reviewer` through multiple review rounds on a pull request, fixing tractable findings between rounds.

## When NOT to use

- One-shot reviews where the user only wants Copilot to look once → just request review and stop
- Reviews by humans or non-Copilot bots — they have different triggering mechanisms
- PRs not yet pushed to origin — Copilot reviews remote PRs only

## Inputs

- PR number (default: current branch's open PR — discover via `gh pr view --json number`)
- Rounds (default: 3)
- Repository (default: current repo)

**Unattended?** When composed by the `ship` skill (no in-session human), read
[references/unattended.md](references/unattended.md) before starting: it
replaces the Ask lane with disposition logging, caps rounds at 2, and — in a
cloud sandbox — maps every `gh` call here to its `mcp__github__*` equivalent.

## The loop

```
for round in 1..N:
    request_copilot_review()
    wait_for_review()
    fetch_inline_comments()
    triage_and_fix()
    if no_findings: break
    push()
```

## Step 1: Request review

`copilot-pull-request-reviewer` is a GitHub App, not a regular user. The standard `--add-reviewer Copilot` and `gh api .../requested_reviewers -f "reviewers[]=copilot-pull-request-reviewer"` calls both fail. The working syntax uses the `@copilot` alias:

```bash
gh pr edit <PR> --add-reviewer "@copilot"
```

This works because the GitHub CLI added explicit support for Copilot as a reviewer alias in March 2026. See <https://github.blog/changelog/2026-03-11-request-copilot-code-review-from-github-cli/>.

Copilot only auto-reviews once per PR (on creation). Every subsequent review must be requested explicitly via the command above — a push never triggers one.

## Step 2: Wait for the review

If a `github-webhook-activity` subscription is active for the PR, simply wait — the webhook notification arrives when Copilot posts. Do not poll.

If no webhook, schedule a wakeup or poll at most every 60-120 seconds.

**The `copilot` author filter (used by every step):** Copilot has TWO author logins depending on the endpoint — review-level (`/pulls/<PR>/reviews`) posts as `copilot-pull-request-reviewer[bot]`, inline-comment-level (`/pulls/<PR>/comments`) posts as `Copilot`, and GraphQL (`gh pr view --json latestReviews`, `.author.login` + `submittedAt`) carries the `[bot]` suffix too. A naive `==` on any one form misses the others. Always filter with a case-insensitive substring match:

```bash
gh api repos/<owner>/<repo>/pulls/<PR>/reviews \
  -q '.[] | select(.user.login | test("copilot"; "i")) | .submitted_at'
```

For background polling, gate the loop on a NEW timestamp (track previous so you wake on any new review, not just the first):

```bash
prev=$(gh api repos/<owner>/<repo>/pulls/<PR>/reviews \
       -q '[.[] | select(.user.login | test("copilot"; "i"))] | last | .submitted_at // ""')
while true; do
  cur=$(gh api repos/<owner>/<repo>/pulls/<PR>/reviews \
        -q '[.[] | select(.user.login | test("copilot"; "i"))] | last | .submitted_at // ""')
  if [ -n "$cur" ] && [ "$cur" != "$prev" ]; then
    echo "review:$cur"; break
  fi
  sleep 60
done
```

A new value means Copilot finished. CI runs in parallel — don't gate the review loop on CI passing.

## Step 3: Fetch inline comments

`gh pr view --json reviews` returns only the review **summary**, not the inline findings. Inline comments live at a different endpoint (same author filter as Step 2):

```bash
gh api repos/<owner>/<repo>/pulls/<PR>/comments \
  -q '.[] | select(.user.login | test("copilot"; "i")) | {path,line,commit_id,body}'
```

Each comment has `path`, `line`, `body`, `commit_id`. Pay attention to `commit_id` — old comments referencing a stale commit are usually already addressed; compare against `gh pr view <PR> --json headRefOid`.

The review **summary** body (posted at the review level, not as inline comments) often contains a "Comments suppressed due to low confidence" section listing extra findings Copilot flagged but didn't surface inline. Read it via:

```bash
gh api repos/<owner>/<repo>/pulls/<PR>/reviews \
  -q '.[] | select(.user.login | test("copilot"; "i")) | .body'
```

Triage those alongside the inline ones — they're real findings, just lower-confidence.

## Step 4: Triage

For each finding, decide one of three:

- **Fix:** the finding is tractable, scope is small (1-2 lines), and the fix is obvious. Apply it.
- **Ask:** the finding is ambiguous, architecturally significant, or you're not confident. Surface it to the user with the suggested fix and a one-line rationale; let them decide.
- **Skip:** nits, style preferences, or findings already addressed in a later commit. Note them in the user-facing summary but don't change code.

Copilot surfaces real bugs, but also suggestions that ignore project conventions or decisions the user consciously made. The middle path keeps the user in the loop only where their judgment is actually needed — neither rubber-stamping every fix nor ceding decisions they own.

If multiple findings cluster into one logical change, fix them in one commit. If they're independent, keep them separate so each commit message tells the truth about what changed.

## Step 5: Push + next round

After fixing:

```bash
git push origin <branch>
```

Then loop back to Step 1. The new review will reference the new HEAD commit.

Post a single PR comment summarizing what was addressed in this round so the audit trail is human-readable:

```bash
gh pr comment <PR> --body "Addressed Copilot findings in <sha>:
- <one line per fix>
- <skipped: ...>"
```

## Stopping conditions

- Round count reached (default 3)
- Zero new findings from Copilot
- All findings in a round are "ask" (no progress possible without user input) — surface and stop
- User says stop

When stopping due to zero findings, tell the user "Copilot returned no new findings. Loop complete." rather than just falling silent.

## Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `Could not resolve user with login 'copilot'` / `Reviews may only be requested from collaborators` | Wrong reviewer alias | Use `@copilot` (with the `@`) — Step 1 |
| `gh pr view --json reviews` is empty of inline comments | Wrong endpoint | Use `gh api /pulls/<n>/comments` |
| Auto-mode classifier blocks an `@copilot` PR comment | Auto mode reads external `@`-mentions as user-summoned writes | Use `gh pr edit --add-reviewer @copilot` (a typed API write) instead of a comment |
| Copilot doesn't re-review on push | Copilot auto-reviews only once per PR | Always re-request explicitly via Step 1 |
| Review never arrives | Copilot may consume Actions minutes starting June 2026 | Check Actions usage and `gh pr view --json statusCheckRollup` for Copilot job status |
| Poll loop never sees the review / `comments` endpoint returns empty | Equality filter on one of Copilot's two logins | The Step 2 author filter, on both endpoints |

## Tracking rounds

Use `TaskCreate` per round before starting so the user can see progress:

```
#N. Round 1: request review + address comments
#N+1. Round 2: re-review + address
#N+2. Round 3: final pass + address
#N+3. Merge PR
```

Mark each round `completed` only after the fix commit is pushed AND the user-facing summary comment is posted. Don't mark a round done while findings are still being deliberated.
