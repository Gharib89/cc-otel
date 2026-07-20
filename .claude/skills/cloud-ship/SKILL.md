---
name: cloud-ship
description: >-
  Run one scheduled cloud-routine fire: pick the frontier issue (oldest open
  `ready-for-agent`, unassigned, no open blockers), drive it to a merge-ready PR,
  and STOP at the merge gate without merging. Composes `ship`. Use only when
  running the scheduled cloud ship routine for Gharib89/cc-otel (the routine
  prompt invokes this skill by name); not for an interactive `/ship`.
---

# cloud-ship

One **fire** = one issue → one merge-ready PR → stop. This skill is the
orchestration the scheduled cloud routine runs unattended; it **composes `ship`**
for the actual issue→PR work and adds only what `ship` is deliberately generic
about: the sandbox bootstrap, the PR cap, the frontier picker, the blocked
hand-off, and — the crux — the **no-human merge-gate override**.

## The fire is one-shot and unattended

There is **no in-session human** during a fire. That single fact drives the two
things this skill exists to enforce on top of `ship`:

- `ship`'s phase-9 merge gate waits for a human "merge" — a human you never
  reach. The override is step 6.
- A fire that can't finish must not strand the issue. Either `ship` reaches
  merge-ready (step 6) or you hand it to a human (step 5). Never leave it spinning.

## Compose, don't inline

Run `ship` by **invoking the Skill tool** (skill `ship`) — never paraphrase or
hand-roll its phases from this skill. `ship` in turn composes `tdd`,
`code-review`, and `copilot-pr-review-loop`; when it reaches those phases, invoke
them via the Skill tool too. All ship as sibling skills in the clone's
`.claude/skills/`.

## The fire

**1 · Bootstrap.** From the repo root run `bash scripts/cloud-ship-bootstrap.sh`.
It syncs the uv workspace and probes for a Docker daemon, printing
`DOCKER=present` or `DOCKER=absent`. **Completion:** it exits 0; record the
`DOCKER` value — it decides the integration gate below. Non-zero → report the
failure and **STOP** the fire.

**2 · PR cap.** Count the repo's open PRs (`mcp__github__list_pull_requests`
state=OPEN). **≥ 3 → report "PR queue full" and STOP** — the operator's
merge-review queue is the bottleneck, not the backlog.

**3 · Pick the work item.** Use the **GitHub MCP connector** (`gh`'s repo/PR/issue
REST endpoints are gated in the cloud sandbox — see *GitHub access in a fire*):

- List open `ready-for-agent` issues, oldest first
  (`mcp__github__list_issues` labels=["ready-for-agent"] state=OPEN
  orderBy=CREATED_AT direction=ASC).
- Walk candidates ascending, skipping any with an assignee (assigned = claimed —
  in flight or awaiting merge).
- **Blocker check** on the first unassigned candidate: it is pickable only if it
  has no *open* blocker. Read its dependencies — try `mcp__github__issue_read`
  `method=get` (look for blocked-by data in the payload), then
  `gh api repos/Gharib89/cc-otel/issues/<n>/dependencies/blocked_by`. Blocked →
  move to the next candidate. **If neither surface exposes dependency data at
  all, report "cannot verify blockers" and STOP** — shipping a dependent issue
  out of order produces a PR built on unmerged schema.

**Completion:** `NUM` = the first unassigned, unblocked candidate. None →
report "nothing ready" and **STOP** — do not open a PR.

**4 · Branch, then ship.** A fire starts you on an auto `claude/<random>` branch.
Switch to the repo's semantic convention **before any commit** —
`<type>/<slug>-$NUM`, `<type>` = `fix` for a bug, `feat` otherwise:

```
git switch -c feat/<slug>-$NUM
```

Then **invoke the `ship` skill on issue $NUM**. While it runs:

- **This branch in the sandbox clone IS `ship`'s phase-0 isolation** — don't
  create a worktree inside it; treat phase 0 as satisfied (its pre-flight
  already-in-flight check still applies).
- **Integration gate by `DOCKER`:** `ship`'s phase-5 gate is
  `scripts/ship/local-gate.sh` — plain when `DOCKER=present`; `--no-docker` when
  `absent`, which marks the Docker-requiring gates (integration pytest,
  schema-drift, docker builds) `deferred-to-ci`: **PR CI is the integration
  gate** — merge-ready requires the CI integration job green, and a
  **schema-touching issue is blocked** (`ship` reference/cc-otel.md: no live
  Postgres → `schema.sql` can't regenerate). No CI configured on the repo yet →
  **blocked** for any `code` change (nothing can prove integration).
- The shared dev DB is out of reach by design — the fire has no `DATABASE_URL`
  and must never construct one.
- Put **`Closes #$NUM`** in the PR body so the squash-merge auto-closes the
  issue and drops it from the queue.
- Follow the clone's `CLAUDE.md` for test / gate / commit rules, and the
  **working standards** below.

**Completion:** `ship` reaches its merge gate (→ step 6) or cannot (→ step 5).

**5 · Blocked hand-off.** If `ship` **cannot** produce a merge-ready PR —
ambiguous / underspecified, needs Docker or CI it doesn't have, or CI can't be
made green — hand it to a human and **STOP**, so it leaves the agent frontier
instead of looping forever. MCP `issue_write` **replaces** whole field sets
(unlike `gh issue edit`'s surgical flags), so read current labels first:

```
mcp__github__issue_read   method=get_labels issue_number=$NUM
    → LABELS = its label names
mcp__github__issue_write  method=update issue_number=$NUM
    labels = LABELS with "ready-for-agent" removed and "ready-for-human" added
    assignees = []           (release the claim — a human picks it up)
mcp__github__add_issue_comment  issue_number=$NUM
    body="<one-line reason it is blocked>"
```

**6 · End at the merge gate — do not merge.** On success `ship` reaches its
merge gate and will try to **wait** for a human "merge." **Override it.** The
moment the PR is merge-ready — CI green, the `copilot-pr-review-loop` converged
(quiet, or 2-round cap with every finding dispositioned), `mergeable` — **post
the PR link + the disposition summary and END the fire.** Do not wait, poll, or
merge. A human merges out of band later; the squash `Closes #$NUM` closes the
issue then. **Leave the issue assigned** — the assignee is the claim, so later
fires skip it until the merge closes it.

## Cloud sandbox quirks

- **Task-list tools (`TaskCreate`/`TaskUpdate`/`TaskList`) are absent — even via
  `ToolSearch`.** Go straight to `ship`'s markdown-checklist fallback for the
  phase list; don't burn a search. The list is a progress / resume aid, **not a
  gate**.
- **Subagent tools are absent too.** `ship`'s delegation rule and model-tier
  table are inert in a fire — run everything inline in the main thread (the
  `code-review` skill's two axes and the implementation subagent included), and
  compensate by projecting every GitHub / CLI call harder, since nothing can be
  offloaded. `ship`'s **scripts still run** — `local-gate.sh` is local-only and
  works in a fire; the `gh`-wrapping ones do not (next section).

## GitHub access in a fire

**Route all GitHub API reads and writes through the `mcp__github__*` connector;
use the `git` CLI for local repository work** (branch/`switch`, status, diff,
commit, fetch, push — brokered credentials). The cloud sandbox's egress proxy
gates `gh`'s repo/PR/issue REST endpoints (`api.github.com`) — they return
`403 "GitHub access is not enabled for this session"` regardless of `GH_TOKEN` —
so every `gh` command in `ship`, its references, the `copilot-pr-review-loop`
skill, and the repo docs they follow (`docs/agents/issue-tracker.md`) fails
here — **including the `scripts/ship/*.sh` helpers that wrap `gh`** (preflight,
claim, reflect, ci-wait, merge; only `local-gate.sh` works in a fire). **This
section outranks every literal `gh` command and `gh`-wrapping script in those
files for the duration of a fire.** (One deliberate exception: the step-3 dependencies probe
*tries* `gh api` as a fallback rung — expect it to 403 and move on.) The merge /
post-merge commands in `reference/merge-gate.md` are out of a fire's path —
step 6 ends the fire before merging — so they need no mapping.

| Where the fire would run `gh …` | Use instead |
|---|---|
| `gh issue view <n> --comments` — read the spec (ship phase 1) | `mcp__github__issue_read` `method=get` (+ `get_comments` / `get_labels`) |
| `gh issue list … --label …` | `mcp__github__list_issues` (`labels`, `state`, `orderBy`) |
| `gh issue edit <n> --add-assignee @me` — the phase-1 claim | `mcp__github__issue_write` `method=update` `assignees=["Gharib89"]` |
| `gh issue edit <n> --remove-assignee @me` / label swaps — the step-5 hand-off | `issue_read method=get_labels` → `issue_write method=update` with the **full** modified label set + `assignees=[]` |
| `gh issue comment <n>` — claim comment, PR-reflect, block reason | `mcp__github__add_issue_comment` |
| `gh pr list` (step-2 PR cap) | `mcp__github__list_pull_requests` |
| `gh pr create` / "open a ready PR" (ship phase 6) | `mcp__github__create_pull_request` (`draft` omitted) |
| `gh pr view <n> --json mergeable,mergeStateStatus` (conflict check, ship phase 8) | `mcp__github__pull_request_read` `method=get` |
| `gh pr view <n> --json reviews,statusCheckRollup` (CI poll) | `pull_request_read` `method=get_reviews` + `get_check_runs` (or `get_status`) |
| Copilot review requests + polling (ship phase 7) | the `copilot-pr-review-loop` skill's own `references/unattended.md` mapping |

Poll CI by re-calling `pull_request_read` on a short delay with a capped number
of attempts; never a detached/background monitor. Reaching the bound is **not**
a licence to proceed: end at step 6 only when the PR is genuinely merge-ready.
If the bound is hit while CI is red/incomplete or can't be made green, that is
the **step-5 blocked hand-off** — never continue unattended past a red or
unfinished gate. If the `mcp__github__*` tools are absent or every call is
denied at fire start, the connector isn't wired → report and STOP (the fire
cannot reach GitHub).

## Working standards

The operator's global coding philosophy does **not** live in the repo's own
`CLAUDE.md` (the clone carries only that) — so it's reproduced here. Read
**[reference/working-standards.md](reference/working-standards.md)** before `ship`
implements and hold it through the whole fire — `ship`, `tdd`, and the repo
`CLAUDE.md` cover tests / gates / merge flow; this fills the judgment layer they
assume.
