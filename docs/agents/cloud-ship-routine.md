# Cloud ship routine

A claude.ai **routine** (research preview) that ships the frontier issue —
oldest open `ready-for-agent`, unassigned, no open blockers — to a merge-ready
PR via the **`cloud-ship` skill** (which composes the **`ship`** skill), then
stops at the merge gate without merging. One issue per fire, at most 3 open PRs
at a time. Manage at https://claude.ai/code/routines or via `/schedule` in the CLI.

## Activation precondition

**Do not enable the schedule until issue #24's CI workflows are merged.** A
Docker-less fire relies on PR CI as its integration gate (see the `cloud-ship`
skill, step 4); with no CI on the repo, every `code` issue bounces
`ready-for-human`. Create the routine, **Run now** once against a known
`ready-for-agent` issue to validate the wiring (especially the step-3 blocker
check — confirm which dependency surface the sandbox can reach), then turn the
schedule on.

## Routine prompt (fixed — paste once; never re-paste on a behavior change)

The agent behavior lives in the repo-tracked **`cloud-ship` skill**
(`.claude/skills/cloud-ship/`), which the cloud sandbox gets via its clone of
`main`. So the routine's Instructions are a short, **fixed** pointer that only
*invokes* the skill — change what a fire does by editing the skill and merging to
`main` (the next clone picks it up), **not** by editing this prompt. Paste this
verbatim into the routine's Instructions once:

```
Objective: produce ONE merge-ready PR for Gharib89/cc-otel and then stop.

Invoke the `cloud-ship` skill via the Skill tool and follow it exactly — do not
paraphrase or inline its steps. The skill is a sibling in the clone's
`.claude/skills/` (alongside `ship`, `tdd`, `code-review`,
`copilot-pr-review-loop`); it bootstraps the sandbox, picks the frontier
`ready-for-agent` issue, ships it via `ship`, and stops at the merge gate
without merging.

If the Skill tool cannot find `cloud-ship`, the repo clone is missing or stale —
report that and STOP rather than improvising the routine by hand.
```

The routine's model selector should be set to the strongest available coding model.

## Cloud environment config (claude.ai web UI — "Edit routine" → environment)

Configure a dedicated environment (e.g. `cc-otel-ship`) and select it for the
routine:

- **Network access → Custom**, Allowed domains (keep "include default package
  managers" checked, for uv/PyPI):
  - `github.com` (`git push`/fetch over HTTPS)
  - Note: all GitHub **API** access (issue picker, PR create/read, review
    requests, comments) runs through the GitHub **MCP connector**, which is
    brokered through Anthropic and **exempt** from this policy — no
    `api.github.com` entry needed (the sandbox gates it with 403 anyway; the
    `cloud-ship` skill's "GitHub access in a fire" table maps every `gh` command
    to its MCP equivalent and outranks the literal `gh` in repo docs during a
    fire).
- **Environment variables:**
  - `GH_TOKEN` = fine-grained PAT, repo `Gharib89/cc-otel`, Contents: write —
    only a fallback credential for `git` push/fetch; leave unset if the
    environment's `git` is already authenticated for `github.com`.
  - **Deliberately absent:** `DATABASE_URL` and all Azure identity vars. Fires
    never touch the shared dev DB or Azure — migrations are verified against
    throwaway Postgres (Docker) or by CI.
- **Setup script:** none — the per-fire `scripts/cloud-ship-bootstrap.sh`
  handles the rest (uv sync, Docker probe).

## Permissions

- Enable **"Allow unrestricted branch pushes"** for `Gharib89/cc-otel` — `/ship`
  pushes `feat/*` / `fix/*` branches; without this, only `claude/*` pushes are
  allowed.
- Connectors: **keep Microsoft Learn and Context7** — MCP traffic is brokered
  through Anthropic, so these work under the Custom network policy (no
  allowed-domain entry needed) and give the agent Azure / library docs during
  `/ship`. The `ctx7` **CLI** (npx) is direct sandbox egress and blocked — the
  connector is the working path. Remove connectors the routine genuinely doesn't
  need. Connectors must be account-level (claude.ai/customize/connectors); local
  `claude mcp add` servers don't appear in routines.

## Concurrency & issue lifecycle

The claim is the **assignee**, per `CLAUDE.md`: `ship` assigns the issue in its
phase 1 and comments the PR link in its phase 6; the picker skips assigned
issues, so a fire never re-picks an issue another fire (or you) already owns.
Because a fire never waits at the merge gate, a merge-ready issue is left
assigned with its open PR; later fires skip it until a human merges and
`Closes #N` closes it. Two backstops:

- **PR cap:** a fire stops immediately when 3 PRs are already open — the
  operator's merge queue, not the backlog, is the bottleneck.
- **Stale-claim recovery:** a fire that dies after claiming but before opening a
  PR leaves the issue assigned with no PR and it is not retried — unassign it by
  hand to requeue. The blocked hand-off (label → `ready-for-human` + unassign)
  is the fire's own step 5, not yours.

## GitHub Actions minutes

The repo is private and Actions minutes are metered — the skills are
frugal-by-design (full local gate before PR-open, one push per review round,
2-round review cap), and CI itself is path-filtered with cancel-in-progress
(#24). **The cadence below is the budget knob:** if the monthly usage report
runs hot, drop to 2–3 fires/week before touching anything else.

## Schedule

Min interval is 1 hour; this routine wants **weekday-daily** — `/schedule
update` → `17 6 * * 1-5`. Each morning: review the open PRs, merge what's ready
(squash; the PR title is the Conventional-Commit subject), and the next fire
picks up whatever the merges unblocked.
