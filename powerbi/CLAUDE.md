# Power BI — frozen, do not author here

**This tree is an archive, not the source of truth.** Since 2026-08-03 the report is owned and
authored in the Power BI Service by Mohamed Atallah (`Mohamed.Atallah@itworx.com`) — ADR-0022. The
`powerbi/` files record the last repo-authored state and will drift from what is published.

So: **do not edit anything under `powerbi/`** — not a visual, not a measure, not a theme token —
however obviously improvable it looks. A change here reaches no consumer and creates a false record of
what the report contains. Report-layer work belongs to the owner; `HANDOVER.md` is his runbook and the
escalation split. Data problems below `marts` are still this repo's (sink, migrations, mart
definitions) and are fixed there, never here.

`ci-powerbi.yml` still gates `powerbi/**` — it exists now as a tripwire, so an accidental edit fails
loudly rather than landing quietly.

## If authorship is ever deliberately resumed

Un-freezing is a decision (ADR-0022 consequences), and the Service's copy — not this tree — is the
base to re-export from. The toolchain that authored this model, kept for that case:

| Task | Reach for |
|---|---|
| Edit report visuals, pages, filters, bookmarks (PBIR) | `pbi-cli` Report-layer commands with `--no-sync`; check the `pbir-gotchas` skill first |
| Edit the report **theme** | Hand-edit `cc-otel-report.Report/StaticResources/RegisteredResources/AIWorx.json` — the report's only custom theme. Never `pbi report set-theme` (orphans it; writes invalid `report.json` — `docs/agents/powerbi-tooling.md`) |
| PBIR / TMDL / pbip format reference | data-goblin `pbip` plugin (`pbip`, `pbir-format`, `tmdl`) |
| Report design / layout / accessibility | data-goblin `reports:pbi-report-design` (invoke on demand) |
| Semantic-model measures | edit TMDL on disk directly — no live connection |
| Validate before commit | `pwsh .github/powerbi/validate.ps1` (mirrors the `ci-powerbi` gate) |

Do **not** use the `pbir-cli` / `create-pbi-report` skills (rejected: license +
no linux wheel) — author with `pbi-cli`. Full roster, setup, and the plugin set:
`docs/agents/powerbi-tooling.md`.
