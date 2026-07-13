# Unattended runs (composed by ship / cloud-ship)

Read this when the loop is invoked by the `ship` skill (or its cloud routine
variant) rather than by a user — there is no in-session human, so the **Ask**
lane has nowhere to go.

## Triage without a human

Replace Fix/Ask/Skip with a two-way disposition — every finding gets exactly one:

- **Fix** — tractable and clearly right: apply the conservative version. When a
  finding cites an API detail, verify it against the **pinned** dependency
  version (context7 / Microsoft Learn) before acting — the bot may "remember"
  an API the installed version doesn't have, and acting on it would be a
  regression.
- **Decline with evidence** — ambiguous, against project conventions, already
  addressed, or contradicted by the pinned docs: record the one-line reason.

Log a one-line disposition per finding as you go. The log lands verbatim in the
round's PR summary comment and in ship's merge-gate summary — a human reads it
there, after the fact, instead of being asked mid-loop.

## Bounded rounds, one push per round

- Rounds cap is **2** in unattended runs (not the interactive default of 3).
- Batch **all** of a round's fixes into a single push — each push burns a CI run
  on a metered private repo. Never push mid-round.
- Stop early exactly as in SKILL.md: zero new findings, or every finding
  declined. Reaching the cap with findings still open is **not** a failure —
  disposition them and let ship's merge gate present the log.

## Cloud sandbox: MCP mapping

In a cloud-routine fire the sandbox egress proxy gates `gh`'s REST endpoints
(403 regardless of `GH_TOKEN`). Route every GitHub call through the
`mcp__github__*` connector instead — this table outranks every literal `gh`
command in SKILL.md for the duration of a fire:

| SKILL.md says | Use instead |
|---|---|
| `gh pr edit <n> --add-reviewer "@copilot"` | `mcp__github__request_copilot_review` |
| `gh api …/pulls/<n>/reviews` (poll for a new review, read summary body) | `mcp__github__pull_request_read` `method=get_reviews` |
| `gh api …/pulls/<n>/comments` (inline findings) | `mcp__github__pull_request_read` `method=get_review_comments` |
| `gh pr view <n> --json headRefOid` (stale-comment check) | `mcp__github__pull_request_read` `method=get` |
| `gh pr comment <n>` (round summary) | `mcp__github__add_issue_comment` |
| `git push origin <branch>` | unchanged — `git` over `github.com` uses brokered credentials |

Apply the same case-insensitive `copilot` author filter to the MCP results —
the two-login split (`copilot-pull-request-reviewer[bot]` vs `Copilot`) exists
in the API payloads, not in `gh`. Poll by re-calling `pull_request_read` on a
60–120 s cadence with a capped attempt count; never a detached background
monitor. If the `mcp__github__*` tools are absent, report that the loop cannot
reach GitHub and stop.
