# Power BI authoring tooling

The installed set for authoring the `powerbi/` report **on disk** (PBIP / PBIR /
TMDL), decided in issue #107 from the research in
`docs/research/pbi-tooling-landscape.md`. On-disk PBIP is the source of truth;
there is no live Analysis Services connection in the loop; publishing is a manual
Power BI Desktop step.

## Roster

| Tool | Role | Install |
|---|---|---|
| **pbi-cli** v3.11.1 (MinaSaad1, MIT) | The authoring engine: offline PBIR Report-layer edits (visuals, pages, filters, themes, bookmarks) with `--no-sync` | `uv tool install --prerelease=allow pbi-cli-tool==3.11.1`, then `pbi-cli skills install` and keep only the 6 offline Report skills (see below) |
| **data-goblin `pbip` plugin** (GPL-3.0) | On-disk format reference: `pbip`, `pbir-format`, `tmdl` skills | Enabled in `.claude/settings.json`, marketplace pinned to tag `v26.25` |
| **data-goblin `reports` plugin** (GPL-3.0) | Design canon: the `pbi-report-design` skill (3-30-300, layout, accessibility) | Same marketplace; on-demand (see "Design canon" below) |
| **`pbir-gotchas` skill** (project-native) | 16 cc-otel PBIR format traps not covered by `pbir-format` | Lives in `.claude/skills/pbir-gotchas/`; source of truth is this repo |
| **`.github/powerbi/validate.ps1`** | Local mirror of the `ci-powerbi` gate — the edit-then-validate loop | In-repo; downloads its own pinned validators on first run |
| **@microsoft/powerbi-report-authoring-cli** v0.1.4 (MIT, preview) | Supplemental PBIR conformance check, **non-blocking** | Runs on demand via `npx`; under evaluation (see below) |

**Install traps:** `--prerelease=allow` is **required** — 3.11.1 depends on
`pythonnet==3.1.0rc0`, and without the flag `uv` silently resolves back to 3.10.10.
And `pbi-cli --version` misreports **3.10.10** even on a correct 3.11.1 install
(stale hardcoded version string upstream); trust `uv tool list` (shows `v3.11.1`),
not `--version`.

## pbi-cli skills — keep offline, drop live

`pbi-cli skills install` registers 13 skills. This repo has no live Desktop/AS
connection in the loop, so **keep the 6 offline Report-layer skills** (Report,
Visuals, Pages, Themes, Filters, Custom Visuals) and **uninstall the 7 live ones**
(DAX, Modeling, Deployment, Security, Docs, Partitions, Diagnostics) so they don't
trigger against a connection that isn't there. Semantic-model measures are edited
directly in the TMDL folder on disk — no `pbi connect`.

Known pbi-cli gaps: no drillthrough authoring (hand-write `pageBinding` or set it
once in Desktop — see `pbir-gotchas` trap 1); emits `visualContainer` schema
`2.7.0` while Desktop's baseline is `2.9.0` (both ajv-valid against their own
`$schema`).

## Design canon — on-demand

The `reports` plugin's `pbi-report-design` skill is available but kept
**invoke-on-demand**: its short description sits in context, its body loads only
when invoked, so it costs nothing per turn until the redesign needs it. If it ever
starts auto-firing unhelpfully, gate it harder with a `skillOverrides` entry
(`"pbi-report-design": "user-invocable-only"`) in `.claude/settings.json`.

The `reports` plugin also ships `pbir-cli` / `create-pbi-report` skills that route
through the **rejected** pbir-cli (non-commercial license + no linux wheel — see
Rejected below). Do not use them; author with pbi-cli instead.

## validate.ps1 — the local gate

```powershell
pwsh .github/powerbi/validate.ps1
```

Mirrors `ci-powerbi` byte-for-byte on the same pinned versions (ajv 8.17.1,
fab-inspector v3.4.0, Tabular Editor 2 2.28.0), reusing the rule files in
`.github/powerbi/`. fab-inspector and TE2 are cached under `.pbi-tools/`
(gitignored) and reused; the ajv leg installs into a gitignored `node_modules/`
in the repo root (`--no-package-lock`, so the tree stays clean). A fourth leg
runs the Microsoft conformance CLI for comparison and is **non-blocking** — its
result never changes the exit code.

**Exit-code contract** (the single source of truth for it):

- `0` clean
- `1` a validation error (a report/model bug)
- `2` tooling failure (download/env issue — not your report's fault)

Requires `node` + `npx` on PATH (Node 20+) and runs on Windows (Tabular Editor 2
is Windows-only).

## Microsoft conformance CLI — under evaluation

`@microsoft/powerbi-report-authoring-cli` (first-party, MIT) authors on-disk PBIR
**and** validates conformance — overlapping both pbi-cli and fab-inspector in this
repo's niche. It is 0.x public preview, so it is wired into `validate.ps1` as a
**non-blocking** supplemental check only. Its command is
`npx -y @microsoft/powerbi-report-authoring-cli@0.1.4 validate <path> --format text`.
Whether it earns a blocking slot (or replaces a mature validator) is decided by
the evaluation ticket, not assumed here. The broader Microsoft
`skills-for-fabric` stack is the strategic successor to re-evaluate at GA.

## Rejected / out

- **pbir-cli** (data-goblin PyPI) — proprietary Non-Commercial license + no linux
  wheel (breaks ubuntu CI). Hard stop for a commercial repo. Do not revisit as an
  authoring engine; pbi-cli covers the need.
- **POC layout scripts** (`scaffold-chrome` / `rewrite-nav` / `add-table-titles` /
  `fix-misc`.ps1) — hardcoded to the old report's pages; the IA is being redesigned
  from scratch, so they encode a layout we are discarding.
- **fab / Fabric CLI, live-connection skills, MCP servers, pbi-tools, pbi-inspector
  v1** — deploy / live / PBIX-era, out of fit for a no-live-connection on-disk loop.
