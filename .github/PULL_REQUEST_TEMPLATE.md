<!-- Title MUST be a Conventional-Commit subject — it becomes the squash-merge
     subject (CLAUDE.md: one issue → one branch → one PR). -->

## Summary

<!-- What changed and why, in 1-3 lines. Link the issue so it auto-closes.
     "No issue — ad-hoc" only for the rare standalone fix (CLAUDE.md exemption). -->
Closes #

## Deviations from plan

<!-- Where the work departed from the issue/brief/plan — an edge case the spec
     missed, a wrong assumption, a conservative fallback chosen. One line each:
     what + why. Write "None" only if the plan genuinely held. -->
- None

## Docs sync — ship in the *same* change

<!-- Tick what applies; strike through (~~...~~) what doesn't. -->

- [ ] **README.md** (root) and the touched concern's README updated (user-facing capability / command / layout change).
- [ ] **CLAUDE.md** updated — this PR changes a command, convention, or environment fact stated there (its own maintenance rule).
- [ ] **CONTEXT.md** vocabulary held (no avoided synonyms); conflicts with `docs/adr/` surfaced, never silently overridden.
- [ ] New top-level concern → path filter added in `.github/workflows/`.
- [ ] N/A — nothing user-visible changed (internal refactor, behavior-restoring bugfix, test/build/comments only).

## Tests

- [ ] New/changed behavior covered — unit (`sink/tests`) or integration (`tests/integration`) — or the Summary states why it can't be.
- [ ] Schema change lands as a dbmate migration with regenerated `db/schema.sql` committed (CI drift gate mirrors this).

## Local gate — mirrors CI, all green

- [ ] `uv run pytest` (integration tests need Docker)
- [ ] `uv run pre-commit run -a`
- [ ] No real credentials or connection strings in the diff — `.env` stays gitignored.
