# Environment schema status is a scheduled check, not a deploy or ship gate

**Status:** accepted. Answers the fork raised in #414, which was `ready-for-human` precisely because
the choice is about where this *class* of check belongs, not just about Power BI.

On 2026-08-03, repointing the report at `ccotel-pg-prod` (#247, ADR-0022) refreshed **green** while
Power BI deleted columns from the semantic model: `dq_finding[subject]`, `[kind]`,
`[first_detected_at]`, `[standing_since]`, columns from all five `bridge_session_*` marts,
`fact_session` and `fact_tool_outcome`. Production was **8 migrations behind** `main`. Every
partition is `SELECT *`, so a database missing those columns still answers the query, and Power BI
reconciles the model by dropping whatever the result set lacks. `validate.ps1`, the BPA leg and a
cached-data screenshot were all green throughout; it surfaced only because a Desktop save
re-serialized the TMDL and `git diff` showed 264 deletions. Publishing at that moment would have
shipped a shrunken model to the manager audience, with visuals silently blank rather than erroring.

The gap was never a missing *capability* — `dbmate status` against an environment already answers
the question exactly. Nothing ran it, and nothing consumed the answer.

## Decisions

- **A scheduled workflow owns the check.** `.github/workflows/env-schema-status.yml` runs
  `dbmate status --exit-code` against each environment on a daily cron (05:00 UTC — 08:00 Cairo, so
  a red run is waiting at the start of the working day) plus `workflow_dispatch` for on-demand runs.
  A scheduled run checks out the default branch, so "pending" means exactly "behind `main`".
- **The red run is the whole alerting surface.** Pending migrations fail the job with a
  `::error::` annotation naming the environment and the fix. No issue is filed, and no state is
  reconciled between runs — a persistent gap simply keeps failing.
- **Detection only.** The workflow never applies a migration; the fix stays the operator-run
  `deploy` workflow. A watchdog that silently repairs prod would hide the very gap it exists to
  surface.
- **Per-environment matrix with `fail-fast: false`,** so one leg's verdict is never hidden by
  another's. A retired environment's leg is deleted; nothing else changes.
- **A leg is deleted when it can no longer go green, not when its environment is deleted**
  (amended 2026-08-07, #439). Originally this ADR tied interim's leg to the cutover gate
  (ADR-0020, ADR-0021). Interim reached that state early: its last deploy was 2026-08-04, the
  report has read prod since 2026-08-03 (ADR-0022), its stores are write-quiet by construction
  (ADR-0021) and its RG is scheduled for deletion (#248 Part B) — so migrations landing on `main`
  would never be applied to it, and deploying purely to green a watchdog is work done for the
  watchdog's benefit. From 2026-08-08 its leg would have failed every day. Because the run-level
  conclusion is `failure` whichever leg fails, `fail-fast: false` keeps prod's verdict *readable*
  but cannot keep the run green — and a run that is red every day trains the team to ignore the
  only alerting surface prod has, so a genuine prod gap (the #414 failure mode) arrives looking
  exactly like the noise. The trigger is therefore **"this leg can never report anything but
  red"**, which precedes decommission; same shape as ADR-0016 pulling the POC RG's deletion
  forward. `continue-on-error` was rejected: a step that always reports and never fails is read by
  nobody, and it leaves a dead leg for #248 Part B to delete anyway. The `INTERIM_*` secrets stay —
  `deploy.yml` still reads them, and interim must stay deployable until its RG is gone.
- **No new access.** It reuses `deploy.yml`'s OIDC app registration, its `<ENV>_`-prefixed secrets,
  and its open/close per-run firewall rule — the public Postgres stays guarded by password alone
  with no standing allow-all (ADR-0018).
- **Named `env-schema-status`, not `*-drift`.** CONTEXT.md locks **Drift** as a telemetry-key term
  and `schema-drift` is already `local-gate.sh`'s name for schema.sql vs the migrations. This is a
  third question, so it borrows dbmate's own word.
- **No `pull_request` trigger,** so `tools/gate_paths.py` never selects it and it is carried in
  `local-gate.sh`'s `EXCLUDED` list rather than as a local gate group.

## Considered options

- **A preflight in `deploy.yml`.** Cheapest — no new workflow, no new schedule. Rejected: it only
  fires when someone is already deploying, which is the one moment the gap is about to close
  anyway. It would not have caught #247, where nobody deployed for days.
- **A gate in the ship path** (`scripts/ship/preflight.sh`, or the `powerbi-ship` Desktop gate).
  Closest to where the damage happened. Rejected on two counts: the ship scripts deliberately touch
  no cloud resource today, so this changes their contract; and like the deploy preflight it is
  human-triggered, blind during exactly the window the gap exists.
- **Filing or updating a GitHub issue on detection.** More visible in the tracker, but needs dedupe
  logic so a standing gap does not file daily. Rejected as machinery ahead of need — revisit if a
  red scheduled run proves easy to ignore.

## Consequences

- The repo gains its first `schedule:`-triggered workflow and a recurring, unprompted signal about
  environment state — previously the repo knew nothing about a deployed environment between manual
  deploys.
- A scheduled run costs metered Actions minutes daily. One short job per live environment; accepted.
- **Accepted residual — the watchdog can be switched off by silence.** This repo is public
  (ADR-0018), and GitHub "automatically disable[s] [scheduled workflows] when no repository activity
  has occurred in 60 days"; re-enabling is manual. So the one failure mode this check cannot cover
  is its own: a quiet repo — increasingly likely now that report ownership has left it (ADR-0022) —
  silently stops the watch. Deliberately not engineered around: every mitigation (an external
  scheduler, a keepalive commit bot) costs more than the failure it prevents, and the check is
  `workflow_dispatch`-able on demand. Not tracked as an issue; if the repo does go quiet, re-enable
  the workflow from the Actions tab.
- A deploy running concurrently with the cron can report a transient pending count and fail. Not
  guarded: deploys are manual and rare, the run is re-runnable, and the failure output names the
  migrations, so the false positive is self-evident.
- A run that cannot reach the database fails too, but says so distinctly (`dbmate` exits 1 for
  pending migrations and 2 for anything else), so a connectivity break never reads as "behind
  `main`" and never sends anyone to run a pointless deploy.
- `powerbi/HANDOVER.md`'s "a green refresh can silently shrink the model" trap stays as written. It
  documents the hazard for the report's owner; this ADR adds the detection the note could not.
