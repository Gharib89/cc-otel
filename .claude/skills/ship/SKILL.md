---
name: ship
description: >-
  Take a tracker issue to a merge-ready PR in one unattended run, stopping only
  at a human merge gate. Composes the `tdd`, `code-review`, and
  `copilot-pr-review-loop` skills. Use when the user wants to ship an issue or
  take an issue through to a PR; also invoked by the cloud ship routine.
argument-hint: "[issue-number]"
---

# ship

Drive one issue from nothing to a **merge-ready PR**, hands-off, stopping only at
a final human merge gate. You run `/ship <issue>`, walk away, and come back to a
PR implemented test-first, integration-tested, self-reviewed, bot-reviewed, and
CI-green — every decision summarized for you to approve before the merge.

This skill is **generic** — everything repo-specific lives in that repo's
**project instructions** (`CLAUDE.md` / `AGENTS.md`). **Read them first** and pull
what the phases below need; if any is missing, surface the gap — don't guess: the
**test command** (run from a worktree), **integrated/live-test** targets + creds,
the **full local-gate set CI runs** (not a fixed triad), **docs-sync rules**, the
**commit-subject convention**, and **whether a review bot exists**. What this
repo's `CLAUDE.md` *doesn't* carry — the dbmate/schema.sql mechanics, the
metered-CI push discipline, the review-bot answer — lives in
**[reference/cc-otel.md](reference/cc-otel.md)**; read it alongside.

## The autonomy contract

`/ship` runs unattended through implementation, testing, review, and CI, to **one
guaranteed stop: the merge gate** — your single review point. It pauses in only
three places:

- **Merge gate (always).** Merging to the default branch is effectively
  irreversible; a human approves it. Never auto-merge.
- **Ambiguity rail (phase 1, only if needed).** Issue too underspecified to derive
  a plan → stop and ask rather than build the wrong thing.
- **Integrated-test hand-off (phase 3, only if needed).** Live-test creds absent →
  hand the exact command back and wait.

Everything else — triaging your own and the bot's findings, fixing, re-running —
is **autonomous**, no mid-loop pause.

**Never proceed on red.** Any failure before the merge gate (failing test, lint,
type-check, CI) gets a bounded self-fix-and-retry (~2 attempts). Still red after that, or the
failure means the approach is wrong → **stop and report**; never merge on red.
Make the report a **fast yes**: attach the concrete evidence (failing output /
live error) and, if cheap, a **verified-working alternative** — a one-glance
approve-or-redirect, not an open-ended "what now?".

## Argument

`$ARGUMENTS` is the issue number. Omitted → ask which issue. Free text rather than
a number → treat it as the task spec directly and skip the issue fetch in phase 1.

## Consult current docs — don't trust training data for APIs

While implementing (phase 2) or triaging findings (phases 4, 7), verify against
**current** docs, not memory — your training data may lag the installed version.
Use **context7** (`ctx7` CLI / MCP) for any library/SDK/CLI, and **Microsoft
Learn** (MCP) for Microsoft / Azure / Power BI when relevant.
This matters most when a review comment cites an API detail: confirm the claim
against the **pinned** version before acting — a bot may "remember" an API the
installed version doesn't have, and acting on it would be a regression.

## Model tiers — match the model to the work

Use the cheapest model that fits; reserve the strong model for judgment. Tag every
subagent with a model explicitly — never default-inherit.

| Work | Model |
|------|-------|
| Investigation / mapping | haiku |
| Mechanical edits & fixes, docs-sync helper, `code-review` skill's **Spec** axis | sonnet |
| Implementation subagent (phase 2) — small lane, or full lane on a tight brief | sonnet |
| Triage judgment (phases 4 & 7), `code-review` skill's **Standards / code** axis, writing the implementation brief | opus |

Gate runs, CI polling, and merge mechanics are **scripts** (*Scripted mechanics*
below) — no subagent, no model, no tokens. Triage and code review are judgment —
running them on the cheap tier under-reads diffs. When you invoke the `code-review`
skill, tier its two axes yourself (Standards = opus, Spec = sonnet — rows above).
Fall back to the nearest available tier rather than running everything on one model.

## Scripted mechanics — run the script, don't hand-roll

The deterministic phase mechanics live in `scripts/ship/` (bash). Contract: one
JSON verdict on **stdout**, a failing step's log tail on **stderr** — never a
full log — exit 0 ok / 1 real failure / 2 tooling. Act on the JSON; don't
re-derive what a script already checked, and never spawn a subagent to do a
script's job. The phase scripts share `scripts/ship/_lib.sh` (sourced, not run)
for the env-file inventory, the `<type>/<slug>-<issue>` branch convention, and
the JSON emit — one source so the two sides of a paired concern can't drift.

| Phase | Script |
|---|---|
| 0 pre-flight | `scripts/ship/preflight.sh <issue>` |
| 0 isolate | `scripts/ship/isolate.sh <issue> <type> <slug>` |
| 1 claim / blocked hand-back | `scripts/ship/claim.sh <issue> [--release]` |
| 5 local gate | `scripts/ship/local-gate.sh [--all] [--no-docker] [--small <node>]` |
| 6 PR-reflect | `scripts/ship/reflect.sh <issue> <pr-url>` |
| 8 CI wait + conflict check | `scripts/ship/ci-wait.sh <pr>` |
| 9 merge mechanics (post-approval only) | `scripts/ship/merge.sh <pr> <issue> [--worktree <path>]` |

A repo without these scripts: fall back to the prose mechanics in each phase and
its reference file.

## The lanes

Every run is **full lane** until the change proves it's **small** — all three keys
hold (assert at phase 2, announced like the class; when unsure, it's *not* small):

1. **No public-surface change.** The **public surface** is the documented,
   user-visible contract: commands, flags, options, choices, defaults, output
   formats, API/output shapes, documented behavior. A small change adds, removes,
   renames, and changes none of it.
2. **Provable without a live call** — a unit/regression test fully proves it; no
   need to hit the live target.
3. **Single-concern** — no new dependency, no new logic branch beyond the fix itself.

Behavior change is allowed — a bugfix *is* one. Small means narrow + locally
provable + invisible to the public surface, not zero-behavior. Small → read
**[reference/small-lane.md](reference/small-lane.md)** — the reduced spine: what
collapses, the floor that never does, when the lane revokes — before continuing.

## The pipeline

Work the phases in order; keep the main thread on orchestration and decisions,
delegating noisy work to subagents. **First**, read
[reference/context-discipline.md](reference/context-discipline.md) — it opens
with the **delegation rule** (when a subagent earns its cost), covers how to keep
this long run from bloating the window, **and names your required first action:
creating the run's ten-item task list** (one per phase below). Don't start phase 0
until that list exists.

**Compose, don't reinline.** Load the `tdd` skill (phase 2), the `code-review` skill
(phase 4), and the `copilot-pr-review-loop` skill (phase 7) through the Skill tool
when their phase begins — never hand-roll their logic. Set the `code-review` skill's per-axis tiers yourself when you invoke it
(opus code / sonnet spec, table above); run finding-**triage** at the judgment tier,
mechanical helpers at the cheap tier (table above).

**0 · Isolate.** **Pre-flight:** run `scripts/ship/preflight.sh <issue>` — on
`"actionable": false` (closed, a PR or branch already exists) **stop and report**
instead of opening a duplicate. (A picker-based runner like the cloud routine
relies on the phase-1 claim to block concurrent re-picks; this guard catches a
*manual* re-run or an already-shipped issue, where there is no picker.) Then
`scripts/ship/isolate.sh <issue> <type> <slug>` creates the sibling worktree on a
fresh `<type>/<slug>-<issue>` branch off the default branch — `<type>` matches
the issue (feat/fix/…) — and copies the gitignored env files in. All
work, commits, and the PR happen from this branch; clean it up after merge.
**Commit as you go** — intermediate messages don't matter, but the PR needs real
commits. (The branch
`<type>` is just a label — the commit/PR Conventional-Commit type may differ once
you see the change, e.g. a `feat/`-branched enhancement best committed as `test:`
or `docs:`. The squash subject, not the branch, drives release tooling.)

**1 · Understand.** Fetch the issue and its comments. Derive what success looks
like. A later authoritative comment can supersede the issue body — **spec
precedence**, detailed in [reference/implement.md](reference/implement.md). **If
it's too vague to plan, stop and ask** (the ambiguity rail).
**Claim it before implementing** — `scripts/ship/claim.sh <issue>` (the assignee
is the claim; idempotent; skip if there's no issue). Don't claim if you stopped on
the ambiguity rail; if you claim then stop blocked, hand the issue back
(`claim.sh <issue> --release`).

**2 · Implement.** Classify the change as `docs` / `code` / `infra`, announce the
class and the skip path it implies — **and whether it passes the three lane keys**
(if so, announce that and follow
[reference/small-lane.md](reference/small-lane.md)) — then implement
test-first per class —
**full detail (classes, TDD override, external-claim verification) in
[reference/implement.md](reference/implement.md).**
**Where implementation runs:** a small-lane change — or a full-lane one once
phase 1 produced a tight brief (success criteria, file list, test plan, known
unknowns) — goes to a **sonnet implementation subagent** that composes the `tdd`
skill and returns a diff summary plus its deviations log as structured output;
the phase-4 opus review is the quality backstop. Keep implementation on the main
thread when the issue is exploratory, the spec is still settling, or the change
touches schema / architecture — a wrong cheap build costs more rework than the
tier saves. **Stay surgical** — implement
only what the issue asks; every changed line should trace to it. An adjacent bug or
cleanup you spot is **out of scope**: file a `needs-triage` issue for it and move
on, don't fix it inline. **Keep a deviations log** from the first edit: whenever
the territory forces a departure from the issue/brief/plan — an edge case the
spec missed, a wrong assumption, a **known unknown** the brief flagged — resolve
it by the conservative option, log what + why, and keep going; the log lands
verbatim in the PR body's **Deviations from plan** section (phase 6) and the
merge summary. If the core work itself balloons mid-flight — the diff
outgrows what one PR can carry, or the fix demands a redesign the issue never
scoped — **stop and report** with a split proposal instead of pushing through (the
ambiguity rail applies mid-run too).

**3 · Integrated test.** Live-test **only what you touched**, on the environment
the bug was reported against — **detail in
[reference/implement.md](reference/implement.md).** A `docs` change — or a
**small-lane** one (key 2) — has nothing to integration-test; skip to the local
gate.

**4 · Sync docs, then self-review.** Sync docs **before** reviewing, so the review
reads the docs edits as part of the diff (the whole point of this ordering: a review
run on a docs-less diff never checks the docs).

**Docs-sync (conditional) — do this first.** Fire **only if this change altered
the public surface** (*The lanes*, key 1) **or observable behavior**. Then bring
the project's documented
artifacts (README, `docs/`, any shipped skill, tests/coverage) back in line **per
the project's docs-sync rules** — using the project's docs-sync subagent at the
mechanical tier if it has one, else by hand — and fold the edits into this change.
**Skip** when nothing user-visible changed — an internal refactor (`infra`), a
bugfix that restores already-documented behavior, test-only / build / tooling
changes, or pure comments; when you skip, say so in one line at the merge gate.

**Self-review.** Invoke the `code-review` skill against the diff — now including the
docs-sync edits — (it runs its two axes on their own tiers — opus for code, sonnet
for spec). **Auto-triage** each finding (this is the canonical definition — phase 7
reuses it): harden rather than rip out capability,
verify nits against the **pinned** dependency versions, reject known non-issues; fix
the valid ones; record a one-line disposition per finding for the merge summary.

**5 · Local gate.** *Precondition:* phase 3 passed **or** the class is `docs` — if
neither holds, you skipped a verification; stop and go back.

Run `scripts/ship/local-gate.sh` green before opening the PR — it maps the diff
to the same concern gates CI's path filters select and mirrors them locally,
secrets grep included. Act on the JSON: `fail` → fix and re-run;
`deferred-to-ci` (Docker-requiring gates under `--no-docker`) → PR CI proves
those, don't re-derive them; `unavailable` → a required tool is missing —
surface it, don't silently skip. **Small lane:**
`local-gate.sh --small <test-node>` per
[reference/small-lane.md](reference/small-lane.md).

**6 · Open PR.** Open a **ready** (non-draft) PR — drafts may not trigger the
project's automated review. Title it as a Conventional-Commit subject derived from
the issue (release tooling reads this on squash-merge). **If the repo has a PR
template (`.github/PULL_REQUEST_TEMPLATE.md` / `docs/pull_request_template.md`),
fill it in** — write the summary and tick / strike-through each checklist item
honestly against the work you did, keeping the `Closes #<issue>` keyword, and
copy the phase-2 deviations log into the **Deviations from plan** section
("None" only if the plan genuinely held). Don't
pass a raw `--body` that bypasses the template; let it populate, then edit. (No
template → a plain body that closes the issue.) Review fires in
phase 7 — nothing to wait for at PR-open.
**Reflect the PR back on the issue** right after opening —
`scripts/ship/reflect.sh <issue> <pr-url>` — so a scheduled run won't re-pick it.

**7 · Review loop.** Invoke the `copilot-pr-review-loop` skill in **unattended
mode** (read its `references/unattended.md`) — Copilot is this repo's only
reviewer, explicitly re-requested each round. The unattended rules bind: 2-round
cap, all of a round's fixes in **one push** (CI minutes are metered —
[reference/cc-otel.md](reference/cc-otel.md)), a one-line disposition per finding
(phase 4's triage definition, judgment tier). **Converged = the loop reports
quiet (zero new findings) or the cap reached with every finding dispositioned**;
the disposition log lands in the merge summary.

**8 · CI.** CI usually runs concurrently from PR-open, so phases 7 and 8 overlap.
Run `scripts/ship/ci-wait.sh <pr>` — it checks for a base-branch conflict first
(a conflicted PR has no merge ref, so its checks sit **pending forever**; the
script won't wait on one), then blocks until every check completes. On
`"conflict"`: fetch the latest default branch, rebase (or merge) it in, fix
conflicts, **re-run the local gate (phase 5)**, push, and re-run the script. On
`"checks-failed"`: fix the named checks and push, then proceed on green — a
lint/format/flake fix earns no extra review round; don't re-request Copilot
for it. `"no-checks"` on a docs-only diff is fine (path-filtered CI).

**9 · Merge gate.** **Hard stop.** Post the summary and wait for the user's
explicit "merge"; on approval run
`scripts/ship/merge.sh <pr> <issue> --worktree <path>` (squash-merge, verify
merged + issue closed, delete branches, remove the worktree). Summary format and
mechanics detail: **[reference/merge-gate.md](reference/merge-gate.md).**

## Reference files

- `reference/context-discipline.md` — the delegation rule; keeping the long run
  from bloating context; the required first-action task list.
- `reference/small-lane.md` — the reduced spine for small changes: what collapses,
  the floor, revocation.
- `reference/implement.md` — phases 1–3: spec precedence, change classification,
  external-claim verification, run-where-it-failed.
- `reference/cc-otel.md` — this repo's specifics: dbmate/schema.sql mechanics,
  the metered-CI push discipline, the review-bot answer, claim ops.
- `reference/merge-gate.md` — phase 9: the merge-summary template and the
  squash-merge / cleanup mechanics.
