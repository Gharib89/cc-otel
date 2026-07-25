# Power BI authoring

The report under `powerbi/` is authored **on disk** (PBIR/TMDL); on-disk PBIP is
the source of truth and publishing is manual from Desktop. Route Power BI work:

| Task | Reach for |
|---|---|
| Edit report visuals, pages, filters, bookmarks (PBIR) | `pbi-cli` Report-layer commands with `--no-sync`; check the `pbir-gotchas` skill first |
| Edit the report **theme** | Hand-edit `cc-otel-report.Report/StaticResources/RegisteredResources/AIWorx.json` — the report's only custom theme. Never `pbi report set-theme` (orphans it; writes invalid `report.json` — `powerbi-tooling.md`) |
| PBIR / TMDL / pbip format reference | data-goblin `pbip` plugin (`pbip`, `pbir-format`, `tmdl`) |
| Report design / layout / accessibility | data-goblin `reports:pbi-report-design` (invoke on demand) |
| Semantic-model measures | edit TMDL on disk directly — no live connection |
| Validate before commit | `pwsh .github/powerbi/validate.ps1` (mirrors the `ci-powerbi` gate) |

Do **not** use the `pbir-cli` / `create-pbi-report` skills (rejected: license +
no linux wheel) — author with `pbi-cli`. Full roster, setup, and the plugin set:
`docs/agents/powerbi-tooling.md`.
