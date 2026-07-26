---
name: powerbi-ship
description: >-
  Take a Power BI issue (`desktop-bound` label; PBIR/TMDL work under `powerbi/`)
  to a merge-ready PR with Desktop-verified visuals. The `ship` spine minus the
  Copilot loop; the merge gate opens the report in Power BI Desktop for the
  human. Use when shipping a Power BI or `desktop-bound` issue — these need
  Windows + Desktop, so route them here, not through `ship` or the cloud
  routine.
argument-hint: "[issue-number]"
---

# powerbi-ship

Drive one Power BI issue from nothing to a **merge-ready PR**, hands-off, with
every visual change verified against rendered Desktop screenshots — the
screenshot is the check. Stops only at a final human merge gate, where the
report opens in Desktop for live review.

This is `ship`'s sibling for the `desktop-bound` lane, not a wrapper — do not
invoke the `ship` skill. It reuses `ship`'s scripted mechanics and autonomy
contract but swaps the verification medium: rendered pages instead of tests,
a Desktop review instead of a Copilot review.

**Read first, alongside this file:**

- **`docs/agents/powerbi-tooling.md`** — the single source of truth for the
  toolchain: pbi-cli, the desktop-bridge screenshot loop (store-install attach
  workaround), the TMDL/TOM verification traps, `validate.ps1`. Every Desktop
  mechanic below is a pointer into it.
- The **`pbir-gotchas` skill** (Skill tool) — load before the first PBIR edit.
- Repo `CLAUDE.md` — worktree discipline, staging rules, commit conventions.

## The autonomy contract

Unattended from claim to gate, including full Desktop control on this machine —
launch, reload, screenshot, close, reopen — as many cycles as verification
needs. Three stops:

- **Merge gate (always).** The human reviews the rendered report and says
  "merge". Never auto-merge.
- **Ambiguity rail (phase 1, only if needed).** Issue too underspecified to
  derive a plan → stop and ask.
- **Foreign-Desktop guard (first launch, only if needed).** `powerbi-desktop
  status` before launching: if a Desktop instance this run did not launch is
  already up, **stop and ask** — the bridge attaches to a PID, and attaching to
  the wrong instance screenshots the wrong copy.

**Kill discipline:** close only Desktop instances this run launched, and always
close them **before** worktree removal — an open `.pbip` holds file locks that
fail `git worktree remove`.

**Never proceed on red.** A failing gate (validate.ps1 leg, CI check, a
screenshot showing a broken visual) gets a bounded self-fix-and-retry
(~2 attempts); still red → stop and report with the evidence.

## Argument

`$ARGUMENTS` is the issue number. Omitted → pick the frontier `desktop-bound`
issue (open, unblocked, unassigned, lowest number) and announce the pick.

## Scripted mechanics — run the script, don't hand-roll

Same contract as `ship`: JSON verdict on stdout, act on it.

| Phase | Script |
|---|---|
| 0 pre-flight | `scripts/ship/preflight.sh <issue>` |
| 0 isolate | `scripts/ship/isolate.sh <issue> <type> <slug>` |
| 1 claim / blocked hand-back | `scripts/ship/claim.sh <issue> [--release]` |
| 3 local gate | `scripts/ship/local-gate.sh` |
| 4 PR-reflect | `scripts/ship/reflect.sh <issue> <pr-url>` |
| 5 CI wait | `scripts/ship/ci-wait.sh <pr>` |
| 6 merge mechanics (post-approval only) | `scripts/ship/merge.sh <pr> <issue> --worktree <path>` |

## The classes

Classify the issue at phase 1 and announce the class — it picks the
verification loop:

- **report** — PBIR only (visuals, pages, filters, themes, bookmarks).
  Verify: edit → `powerbi-desktop reload` → screenshot → read the PNG.
- **metadata-only** — report-class edits where nothing moves on canvas (alt
  text, tab order): pages render pixel-identical to `main`, so a screenshot
  carries zero review signal. Verify structurally instead: programmatic
  assertions covering the issue's ask exhaustively (e.g. every data visual
  carries altText, every chrome/label at `tabOrder:-1`, no interactive or
  structural visual touched) plus a clean `validate.ps1` against `main`'s
  baseline.
- **model** — TMDL only (measures, columns, relationships, hygiene).
  Verify: `validate.ps1`'s TE2/TOM legs parse it, but Desktop **load** is the
  real test and fails *silently* — close + reopen the `.pbip`, confirm the
  model loaded (not `Untitled`), then TOM table-refresh + ADOMD DAX checks per
  `powerbi-tooling.md`. `reload` does **not** apply TMDL changes.
- **mixed** — both; run both loops (model first — visuals bind to the measures).

Every class ends in evidence: rendered pages when pixels move, structural
assertions when they don't.

## The pipeline

Keep the main thread on orchestration and the Desktop loop (it's stateful —
attached PID, refresh state); delegate only the phase-3 review axes.

**0 · Isolate.** `preflight.sh` — on `"actionable": false` stop and report.
`isolate.sh <issue> <type> <slug>` creates the sibling worktree and copies env
files. Then copy the data cache so screenshots are data-populated without a
manual refresh (gitignored, never committed):

```powershell
$dst = "<worktree>\powerbi\cc-otel-report.SemanticModel\.pbi"
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item powerbi\cc-otel-report.SemanticModel\.pbi\cache.abf $dst
```

The worktree's cache.abf is discarded at cleanup — the main checkout keeps its
own. Commit as you go, staging explicit paths only.

**1 · Understand + claim.** Fetch the issue and comments (a later authoritative
comment supersedes the body). Derive success criteria: the list of pages/visuals
that must render correctly and, for model work, the measure values that must
verify. Classify (report/model/mixed) and announce. Too vague → ambiguity rail.
Then `claim.sh <issue>`; if you later stop blocked, `claim.sh <issue> --release`.

**2 · Implement.** Load `pbir-gotchas` before the first PBIR edit; the
data-goblin `pbip` / `pbir-format` / `tmdl` skills are the format reference.
PBIR edits go through pbi-cli `--no-sync`; TMDL is edited directly on disk.
Run the class's verification loop (foreign-Desktop guard before the first
launch; store-install attach workaround, calc-banner clearing, and all TMDL
traps per `powerbi-tooling.md`). Iterate edit → render → read until every
success criterion from phase 1 shows correct in a screenshot — data values,
not just layout. **Stay surgical**: every changed line traces to the issue or to a
rung-1 ad-hoc fix named in the PR body; adjacent finds go through the repo's
**fix-first disposition ladder** (`CLAUDE.md`, *Way of working*) — fix the mechanical
ones here, ticket only the genuine forks. **Keep a deviations log** — every
forced departure from the issue's plan, resolved conservatively, logged for the
PR body and merge summary.

**3 · Self-review.** Two axes, subagents. This skill never *requests* a review
bot, but the repo auto-runs `copilot-pull-request-reviewer` on every PR — a
`desktop-bound` PR carries Copilot comments regardless, and they get triaged at
the merge gate like any other finding rather than skipped because this skill
says "no Copilot":

- **Spec (sonnet):** issue + full diff → confirm every ask landed; multi-part
  issues checked bullet by bullet.
- **Design (opus):** load the `pbi-report-design` skill, judge the final
  screenshots against the canon (3-30-300, alignment, color discipline,
  accessibility). Model-class diffs additionally get a DAX correctness read
  (filter-context and time-intelligence traps — `powerbi-tooling.md` lists
  known ones).

Auto-triage the findings: fix the valid, record a one-line disposition per
finding for the merge summary. Run each finding down the **fix-first disposition
ladder** and default to fixing, not filing — the design axis is a finding
*generator*, so a long list is what it does, not a signal that the diff is
defective. A canon divergence already settled in an ADR is answered by the ADR,
not re-filed. If a change altered documented behavior or
vocabulary, sync the coupled docs (`CONTEXT.md`, `docs/agents/powerbi-tooling.md`)
in the same change.

**4 · Local gate + PR.** Run `local-gate.sh` **once, now** — after the visual
loop converges, before the PR — not per iteration (the screenshot is the check
during the loop; `validate.ps1` is the pre-commit gate). Green → open a ready
PR: Conventional-Commit title, template filled honestly, `Closes #<issue>`,
deviations log in its section, and a **"Pages verified"** list naming each
page/visual confirmed by screenshot. Do not request any review bot (the
auto-review fires on its own; see step 6). Then `reflect.sh <issue> <pr-url>`.

**5 · CI.** `ci-wait.sh <pr>`. On `"conflict"`: rebase, re-run the local gate,
push, re-run. On `"checks-failed"`: fix and push. Note: local `validate.ps1`
runs Windows fab-inspector where CI runs the linux one — a CI-only red is
possible; fix it like any red, don't dismiss it as environmental.

**6 · Merge gate.** **Hard stop.** First collect the auto-review: inline threads
come from `gh api repos/<o>/<r>/pulls/<n>/comments` and the top-level body from
`gh pr view <n> --json reviews` — inline comments do **not** appear in `reviews`,
so both calls are needed. Fold any finding into the gate summary with a
disposition each rather than letting the human discover it; reply in-thread with
`POST .../pulls/<n>/comments/<id>/replies`, passing the body via `--input
<json-file>` (a `-f body="…"` containing quotes gets shredded into `accepts 1
arg(s), received 5`). Then launch Desktop on the **worktree's** `.pbip`
(store-install: `Start-Process "shell:AppsFolder\$appId" -ArgumentList $pbip`
per `powerbi-tooling.md`), wait for `status` ready, then post the merge summary
with the final screenshots **in chat** — format and approval mechanics in
[reference/merge-gate.md](reference/merge-gate.md) (metadata-only class:
textual evidence instead, per its variant there). The human reviews live in
Desktop; remind them not to **save** there (a Desktop save re-serializes the
whole pbip — wide churn on the branch). On "merge": close the run's Desktop
instances first, then `merge.sh <pr> <issue> --worktree <path>`. On change
requests: apply on the same branch, re-verify (screenshots), re-run the local
gate, return to this gate.
