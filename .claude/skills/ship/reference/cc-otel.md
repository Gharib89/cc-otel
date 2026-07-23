# cc-otel specifics

What this repo's `CLAUDE.md` doesn't spell out. `CLAUDE.md` stays authoritative
for commands, layout, and conventions — nothing here repeats it.

## dbmate / schema.sql mechanics

`db/schema.sql` is **generated** by dbmate, not hand-edited: `dbmate up` applies
pending migrations **and** rewrites the dump — both need a **live Postgres**
behind `DATABASE_URL`. A schema-touching change is complete only when the new
migration file *and* the regenerated `schema.sql` are in the same commit; CI's
schema-drift gate fails the PR otherwise.

Where to get a live Postgres, in order:

1. **Throwaway container** — Docker present: run a disposable Postgres, point
   `DATABASE_URL` at it, `dbmate up`, commit migrations + `schema.sql`. The
   shared dev DB is never a test or regen target for an unattended run.
2. **Interactive session only** — the gitignored `.env`'s dev-DB `DATABASE_URL`
   works, but applying to dev is the operator's call at merge, not part of a
   ship run.
3. **Neither available** (cloud fire, no Docker): a schema-touching issue is
   **blocked** — hand it off; a PR with drifting `schema.sql` can never go green.

## Metered CI — push discipline

Private repo; every push to an open PR burns metered Actions minutes. So: the
full local gate green **before** PR-open (CI should pass first try), all of a
review round's fixes in **one push**, and a push only when the tree actually
changed — re-running CI on unchanged code is pure spend.

## Review bot

No auto-reviewer app is installed. Review = phase 7's `copilot-pr-review-loop`
(explicit `@copilot` requests, unattended rules). Phase-4 self-review always
runs — it is the only review a `docs`-class change gets besides CI.

## Integrated test target

The live target is the **testcontainers end-to-end suite**
(`tests/integration/`) — Docker required, throwaway Postgres per run. "Run where
it failed" resolves here to: reproduce against a fresh container with migrations
applied, never against the shared dev DB.

## Claim ops

Claim (phase 1) = `scripts/ship/claim.sh <n>`; the frontier query skips assigned
issues, so the assignee **is** the claim. Reflect the PR (phase 6) with
`scripts/ship/reflect.sh <n> <pr-url>`. If you claimed and then stopped blocked,
release (`claim.sh <n> --release`) so the issue re-enters the frontier — or hand
it to a human per the cloud routine's rules when in a fire.

## local-gate.sh's workflow-name -> gate-group mapping is coupled to CI

`scripts/ship/local-gate.sh` derives *which* workflows a diff triggers by
parsing `.github/workflows/*.yml`'s own `paths:` filters (`tools/gate_paths.py`,
#226) — a `paths:` edit alone no longer touches the script. What remains
coupled is the **workflow name -> local gate-group mapping** (python,
integration, docker, iac, installer, bootstrap, ci-powerbi) plus the explicit
exclusion list (`deploy`, `publish-images` — workflows with no local mirror). A
brand-new workflow needs a gate group or an exclusion-list entry in the same
PR — otherwise the script fails loudly (`unavailable`/TOOLING) instead of
silently letting "local gate green" mean less than "CI green".
