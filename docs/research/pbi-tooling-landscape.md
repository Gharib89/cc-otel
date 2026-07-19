# Power BI agentic tooling landscape — the on-disk PBIP/PBIR/TMDL authoring loop

**Ticket:** #105 (wayfinder research, under map #104). **Date:** 2026-07-19.

**Question:** What is the current best-of-breed set of Claude Code tooling for
authoring Power BI reports **on disk** (PBIP/PBIR/TMDL) for *this* repo —
where on-disk PBIP is the source of truth, there is **no live Analysis Services
connection** in the automated loop, and publishing is a manual Power BI Desktop
step? Survey and rank the data-goblin `power-bi-agentic-development` plugins,
the CLIs (pbi-cli, pbir-cli, fab, Tabular Editor 2, fab-inspector, pbi-inspector),
and any newer/alternative options; produce a **recommended install set** to feed
install ticket #107.

**Method:** Every external claim traces to a **primary source** — the GitHub API
(`gh api`, absolute `pushed_at`/release timestamps, not the misleading relative
dates on release pages), PyPI/npm registry JSON, and Microsoft Learn. The POC
baseline was inspected directly at `../archive/cc-otel-azure` (`tools/`,
`.claude/skills/pbir-gotchas-cc-otel`, `CLAUDE.md` lines 63–116). The current
repo state was inspected at `powerbi/`, `.github/powerbi/`, `.claude/`, and
`.github/workflows/ci-powerbi.yml`. Two prior research docs are load-bearing and
are **not re-derived** here: `docs/research/dev-tooling-stack.md` (#33 — the
validation triad) and `docs/research/pbi-cli-visual-authoring.md` (#95 — pbi-cli
in depth). **UNVERIFIED** = not confirmed at the owning source this pass.

---

## TL;DR — the recommended install set (ranked, for #107)

| # | Item | Verdict | Why (one line) |
|---|---|---|---|
| 1 | **pbi-cli v3.11.1** (MinaSaad1) — offline Report-layer skills only | **Adopt now** (dev machine) | MIT, mature, offline PBIR authoring already validated in #95; the primary authoring engine |
| 2 | **Local `validate.ps1` loop** = ajv + fab-inspector v3.4.0 + TE2 2.28.0 | **Adopt now** (port from CI) | Closes the edit-then-validate loop on the dev machine; CI already pins all three |
| 3 | **`pbir-gotchas` project-native skill** (port + scrub the POC one) | **Adopt now** | 16 PBIR format-level traps, still valid; cheap; format-level not IA-level |
| 4 | **data-goblin `pbip` plugin**, pinned **v26.25** | **Adopt now** | tmdl / pbip / pbir-format on-disk reference; pin before the 26.26–26.38 breaking window |
| 5 | data-goblin `reports:pbi-report-design` (design canon) | **Optional** | 3-30-300 / layout / accessibility guidance for the #104 redesign; watch context budget |
| 6 | **@microsoft/powerbi-report-authoring-cli** + `skills-for-fabric` | **Track / re-eval at GA** | First-party, MIT, on-disk PBIR **+ conformance validation** — the likely successor; still 0.x preview |
| — | **pbir-cli** (data-goblin PyPI) | **Reject** | Proprietary **Non-Commercial** license + **no linux wheel** — unusable in a corporate repo / ubuntu CI |
| — | POC `scaffold-chrome/rewrite-nav/add-table-titles/fix-misc.ps1` | **Do not port** | Hardcoded to the OLD report's page/visual names; #104 redesigns IA from scratch |
| — | fab / Fabric CLI, semantic-models live skills, pbi-desktop, etl, fabric-admin, paginated-reports | **Skip** | Deploy / live-connection / out-of-fit for a no-live-connection on-disk loop |
| — | pbi-tools; pbi-inspector v1; Power BI MCP servers | **Skip** | PBIX-era dormant; superseded by fab-inspector; MCP token cost > on-demand CLI |

**One-paragraph rationale.** The authoring engine is **pbi-cli** (MIT, offline
PBIR Report layer, already proven in #95) — *not* the data-goblin `reports`/
`custom-visuals` skills, because those route through **pbir-cli**, whose
**Non-Commercial license and missing linux wheel** make it a non-starter for an
ITWorx corporate repo. From data-goblin we take only the license-clean, pure-
knowledge **`pbip` plugin** (pinned to 26.25, ahead of the maintainer's declared
breaking-transition window) plus optionally the design-canon skill. We port the
**local validation loop** (the same ajv + fab-inspector + TE2 triad the repo
already pins in CI) so authoring can validate before pushing, and we re-home the
**`pbir-gotchas`** trap list. Microsoft's first-party `skills-for-fabric` /
`powerbi-report-authoring-cli` is the strategic track to adopt once it leaves
preview — it is MIT, on-disk, and adds PBIR **conformance validation**, with none
of pbir-cli's license baggage.

---

## 1. Baseline inspected — the POC kit vs what this repo already has

**POC kit** (`../archive/cc-otel-azure`, verified this pass):

- `tools/validate-all.ps1` → orchestrates three validators: `validate-report.ps1`
  (ajv over `tools/pbir-validator/validate-pbir.mjs`), `validate-fabric.ps1`
  (vendored **fab-inspector v3.1.1** `PBIRInspectorCLI.exe` + `cc-otel-rules.json`),
  `validate-model.ps1` (vendored **Tabular Editor 2** `-A` BPA + `BPARules.json`).
  Exit-code contract: 0 clean / 1 validation error / 2 tooling failure. **Sound
  design; port the orchestration, not the vendored binaries.**
- `tools/pbi-inspector/` — legacy **v1.9.4 PBIX-only**, already marked superseded.
- `tools/fab-inspector/`, `tools/tabular-editor/`, `tools/pbir-validator/` — the
  three real validators (fab-inspector + TE2 + ajv).
- `.claude/skills/pbir-gotchas-cc-otel/SKILL.md` — **16 numbered PBIR traps**
  (drillthrough filter type, card-needs-Measure, slicer literals, actionButton
  shape, schema-version fallback, theme-vs-per-visual precedence, `shape` fill
  bug, `pageNavigator` hide, `textbox` has no visualLink, …). Format-level, not
  IA-level — **still valid**, worth porting.
- `tools/{scaffold-chrome,rewrite-nav,add-table-titles,fix-misc}.ps1` — one-off
  layout mutators **hardcoded to the old report's page folders** (`overview`,
  `cost-economics`, `tool-quality`, `drilldown`, …) and visual names
  (`nav-btn-overview`, `title-page`, `matrix-model-effort`, …). **Throwaway** —
  #104 redesigns the IA from scratch, so these encode a layout we are discarding.

**Current repo already has** (verified this pass):

- `.github/workflows/ci-powerbi.yml` — the validation triad **already modernized
  into CI**: `pbir-schema` job (ajv 8.17.1 + `.github/powerbi/validate-pbir.mjs`,
  ubuntu), `fab-inspector` job (**v3.4.0** linux-x64 downloaded + `-formats
  GitHub`, ubuntu), `bpa` job (**TE2 2.28.0** portable + `-A` `BPARules.json`,
  windows-latest, driven via `Start-Process -PassThru` for exit-code fidelity).
- `.github/powerbi/` — `validate-pbir.mjs`, `fab-inspector-rules.json`,
  `BPARules.json`, `README.md` (the CI copies of the POC rule files).
- `powerbi/` — `cc-otel-report.pbip`, `cc-otel-report.Report/` (PBIR),
  `cc-otel-report.SemanticModel/` (TMDL), `theme.json`, `branding/`.
- **Gaps:** no `.claude/settings.json` (⇒ **no data-goblin plugins installed**),
  **no `pbir-gotchas` skill** in `.claude/skills/`, and **no local validation
  wrapper** — the triad exists only in CI, not as a dev-machine edit-then-validate
  loop. Those three gaps are exactly what #107 must close.

---

## 2. data-goblin/power-bi-agentic-development — surveyed at source

Source: `gh api repos/data-goblin/power-bi-agentic-development` and its
`.claude-plugin/marketplace.json` + per-skill `SKILL.md` frontmatter.

**Maturity:** owner Kurt Buhler; **798★**, **GPL-3.0**, created 2026-01-15, last
push **2026-07-18** (actively maintained, self-described weekly cadence). Versioning
switched from semver to **CalVer `vYY.WW`**; latest published tag **v26.28**,
`main` at **26.29.0**. **Critical, quoted from README:** *"Versions 26.26 through
26.38 are a **deliberate breaking transition.** Skills may be consolidated,
renamed, removed, or made less automatic between weekly releases in this range.
Pin **26.25 or earlier** if you need the pre-transition skill structure."* ⇒ any
install must **pin 26.25**.

**Plugin set grew 4 → 11 since the POC.** POC families (pbip, semantic-models,
reports, fabric-cli) all remain; new: `goblin-mode`, `tabular-editor`,
`pbi-desktop`, `paginated-reports`, `fabric-admin`, **`custom-visuals`** (the
visual skills extracted from `reports`), `etl`.

**Skills by on-disk vs live fit** (judged from each SKILL.md). ON-DISK = pure
file work on PBIP/PBIR/TMDL; LIVE = needs a running AS/Desktop/Fabric/tenant
connection; MIXED = file authoring on-disk but validate/refresh/publish/usage
steps live.

| Plugin | Skill | Fit | Note |
|---|---|---|---|
| **pbip** | `pbip`, `pbir-format`, `tmdl` | **ON-DISK** | All 3 unchanged since POC; `tmdl` explicitly "without Desktop open". **The keeper.** |
| semantic-models | `standardize-naming-conventions` | ON-DISK | TMDL naming |
| semantic-models | `dax` | LIVE | perf tuning needs server timings |
| semantic-models | `power-query` | MIXED | authoring on-disk, testing hits sources |
| semantic-models | `refresh-semantic-model`, `lineage-analysis` | LIVE | REST/tenant |
| semantic-models | `semantic-model` (**new**) | MIXED | absorbed the old `review-semantic-model` (now gone) |
| **reports** | `pbi-report-design`, `modifying-theme-json` | **ON-DISK** | design canon + theme (guidance) |
| reports | `pbir-cli`, `create-pbi-report` | MIXED | **route through `pbir-cli`** (see §4 — rejected on license) |
| reports | `review-report` | MIXED | structure review on-disk; usage analysis live |
| custom-visuals (**new**) | `deneb-visuals`, `svg-visuals`, `python-visuals`, `r-visuals` | ON-DISK* | *mutations run via `pbir-cli` (license issue) |
| custom-visuals | `powerbi-custom-visuals` (**new**) | LIVE-ish | `.pbiviz` dev toolchain + live-preview |
| fabric-cli | `fabric-cli` | LIVE | cloud only; POC's `migrating-fabric-trial-capacities` **removed** (UNVERIFIED where it went) |
| tabular-editor (**new**) | `bpa-rules`, `c-sharp-scripting`, `te-cli`, `te2-cli`, `te-docs` | MIXED | rule/script files on-disk; running needs a model |
| pbi-desktop (**new**) | `connect-pbid` | LIVE | Desktop must be running |
| goblin-mode/paginated-reports/fabric-admin/etl | (setup / RDL / tenant / Spark-DuckDB) | N/A / LIVE | out of fit |

**Install (verbatim from README):**
`claude plugin marketplace add data-goblin/power-bi-agentic-development`, then
`/plugin` picker or `claude plugin install <plugin>@power-bi-agentic-development`.
README warning, quoted: *"Don't install every plugin. Each skill competes for the
agent's attention and context window… Prefer installing plugins scoped to a
project."* (The `enabledPlugins` settings.json path is the standard Claude Code
mechanism but is **UNVERIFIED** — not printed in this README.)

**What we actually take from data-goblin:** only the **`pbip` plugin** (license-
clean knowledge, pinned 26.25), and *optionally* `reports:pbi-report-design` for
the redesign. The bulk of the report/custom-visuals value is gated behind
**pbir-cli**, which we reject in §4 — and their skills would also compete for
context with pbi-cli's own skills (§3).

---

## 3. pbi-cli (MinaSaad1) — the authoring engine (recap of #95, freshened)

Confirmed still **v3.11.1** (tag `v3.11.1`, published **2026-05-04**), **MIT**,
**418★**, repo pushed 2026-07-19 (`gh api repos/MinaSaad1/pbi-cli`). Full analysis
in `docs/research/pbi-cli-visual-authoring.md`; the decisive facts for #107:

- **Offline Report layer** (`report`, `visual`, `filters`, `format`, `bookmarks`,
  `themes`) edits `.pbip` PBIR JSON with **no Desktop connection** — AFK-safe with
  `--no-sync`. 32 visual types, `bulk-*` batch ops, conditional formatting
  (`background-measure/gradient/conditional`), `--json` on every command.
- **Semantic-model layer** (`measure`, `dax`, …) needs `pbi connect` to a running
  Desktop ⇒ **HITL**; we don't need it (measures live in TMDL on disk).
- **Windows + Python 3.10+.** Install `pipx install pbi-cli-tool==3.11.1`, then
  `pbi-cli skills install` registers **13** skills — **keep the 6 offline
  Report-layer skills** (Report, Visuals, Pages, Themes, Filters, Custom Visuals)
  and **uninstall the 7 live ones** (DAX, Modeling, Deployment, Security, Docs,
  Partitions, Diagnostics) so they don't trigger against a connection we won't have.
- **Known gaps** (from #95): drillthrough authoring unsupported (hand-write
  `pageBinding` or set once in Desktop); no documented `--z` flag; emits
  visualContainer **2.7.0** while the repo baseline is **2.9.0** (both ajv-valid
  against their own `$schema`).

pbi-cli's own skills **overlap** data-goblin's `reports` skills — installing both
wastes context. Choosing pbi-cli as the engine is another reason to keep the
data-goblin footprint to the `pbip` knowledge plugin only.

---

## 4. pbir-cli (data-goblin PyPI) — REJECTED on license + platform

Source: `https://pypi.org/pypi/pbir-cli/json`. **v0.9.27**, released
**2026-07-17**, by Kurt Buhler & Maxim Anatsko; repo `data-goblin/pbir-cli`
(confirmed data-goblin's own package, **not** `maxanatsko/pbir.tools`). It is the
CLI the data-goblin `reports`/`custom-visuals` mutation skills drive.

Two blockers for this repo:

1. **License: proprietary "Custom Non-Commercial License"** — commercial use
   needs written permission and derivative works are forbidden. cc-otel is an
   ITWorx (commercial) repo; this is a hard stop.
2. **Binary wheels for win-x64 + osx-arm64 only — no linux wheel** ⇒ cannot run
   on the ubuntu CI runners the repo standardizes on.

Because the on-disk *authoring* need is met by pbi-cli (MIT) and, prospectively,
Microsoft's MIT CLI (§5), there is no reason to take on pbir-cli's license.
**Reject** — and with it, deprioritize the data-goblin `reports`/`custom-visuals`
*mutation* skills (their knowledge-only siblings — `pbi-report-design`,
`modifying-theme-json`, `pbir-format` — remain fine as guidance).

---

## 5. Newer / first-party alternatives since the POC

### microsoft/skills-for-fabric — the strategic track (adopt at GA)

Source: `gh api repos/microsoft/skills-for-fabric`. **MIT**, **824★**, created
**2026-02-17** (did not exist at POC), latest release **v0.3.8 (2026-07-16)**,
actively pushed. Ships a **Claude Code plugin marketplace** manifest
(`.claude-plugin/marketplace.json`, marketplace `fabric-collection`); the relevant
bundle is **`powerbi-authoring`** (5 PBI skills + a pre-wired modeling MCP).
Install: `/plugin marketplace add microsoft/skills-for-fabric` →
`powerbi-authoring@fabric-collection`.

The on-disk-relevant skills and the **first-party MIT npm CLIs** they wrap
(verified on the npm registry):

- **`powerbi-report-authoring`** skill → **`@microsoft/powerbi-report-authoring-cli`**
  v**0.1.4** (2026-07-08, **MIT**). Creates/modifies **on-disk PBIR** (pages,
  visuals, filters, themes) **plus PBIR conformance validation** — "Public
  preview." **This is the standout new tool:** it overlaps *both* pbi-cli
  (authoring) and fab-inspector (validation) in exactly this repo's niche, is
  first-party, and carries **no license problem**.
- **`powerbi-report-design`** skill → emits a "Design Brief"; decides *what* the
  report looks like, does **not** write PBIR; no live connection.
- `powerbi-report-authoring` also uses **`@microsoft/powerbi-desktop-bridge-cli`**
  v0.1.2 (screenshot/reload over a named pipe — Desktop-bound, Windows) and
  `powerbi-modeling-mcp` v0.5.0-beta.11 (semantic-model MCP, Node 20+, beta) for
  the live legs — neither fits headless CI, but the pure PBIR-authoring CLI does.

**Verdict:** the whole stack is **0.x / "Public preview" / beta**, versus the
mature fab-inspector v3.4.0 + TE2 2.28.0 + pbi-cli v3.11.1 the repo can rely on
today. **Track it; re-evaluate for adoption at GA/1.0** — it is the most likely
consolidator of the authoring+validation space and the license-clean first-party
answer. A low-risk early move (optional for #107): adopt
`@microsoft/powerbi-report-authoring-cli` **solely for its PBIR conformance check**
as a supplement to ajv + fab-inspector.

### Other options (all Skip)

- **fab / Fabric CLI** (`ms-fabric-cli` v1.6.1, 2026-04-28, MIT) — deploy/automation
  over the Fabric platform, **needs live auth, not a validator**. Out of scope
  per #104 (manual Desktop publish).
- **Power BI / Fabric MCP servers** — `@microsoft/powerbi-modeling-mcp` (beta,
  live-or-on-disk model authoring) and the HTTP FabricIQ MCP (live only). MCP
  holds large tool schemas in-context every turn; for a token-conscious loop an
  on-demand CLI is cheaper. No credible third-party on-disk PBI MCP found. Skip.
- **pbi-tools** (pbi-tools/pbi-tools) — **1.2.0, 2025-01-06**, AGPL, PBIX-era,
  no PBIR. Dormant. Skip.
- **pbi-inspector v1** (NatVanG/PBI-Inspector, `PBIXInspectorCLI`) — v1.9.4
  **2023-11-19**, PBIX-only, superseded by fab-inspector. Skip (already dropped).
- **TMDL tooling** — Microsoft's **TMDL VS Code extension** (`analysis-services.TMDL`)
  is a human editor aid, not a headless CI linter. **No standalone cross-platform
  TMDL linter/formatter CLI exists** (UNVERIFIED — none found). Cross-platform BPA
  on TMDL: only **semantic-link-labs `run_model_bpa`**, which needs a live/published
  Fabric model — doesn't fit the on-disk loop. TE2 `-A` (Windows) stays the only
  offline TMDL BPA.

---

## 6. Validation loop — keep the incumbent triad, add a local wrapper

The repo's CI already pins the right three, and #33 established them as best-of-breed;
nothing surveyed this pass beats them for an on-disk Import-mode PBIP report:

1. **ajv PBIR schema validation** (`.github/powerbi/validate-pbir.mjs`, ajv 8) —
   validates each PBIR file against the exact Microsoft `$schema` it declares. No
   off-the-shelf substitute; keep.
2. **fab-inspector v3.4.0** (NatVanG/fab-inspector, MIT, 2026-06-29 — newest;
   cross-platform binaries incl. linux-x64, Docker image) — declarative PBIR rule
   engine; carries `fab-inspector-rules.json` forward.
3. **Tabular Editor 2 2.28.0** (`-A` BPA, MIT, Windows-only) — semantic-model BPA
   over the TMDL folder; the only offline TMDL BPA.

**#107 action:** add a **local `validate.ps1`** (dev-machine mirror of the CI
triad, reusing `.github/powerbi/` rule files) so the edit-files-then-validate loop
runs before push — the one piece of the POC `validate-all.ps1` design worth
porting. Reject the four hardcoded layout scripts.

---

## Open / UNVERIFIED items

- data-goblin `enabledPlugins` settings.json snippet — not printed in the README
  (standard Claude Code mechanism, but not quoted at source).
- Destination of the removed data-goblin `migrating-fabric-trial-capacities`
  skill (merged elsewhere vs deleted) — not located.
- fab-inspector VS Code extension — none found this pass (POC README claimed one).
- Standalone cross-platform TMDL linter CLI — none found.
- PBIR remains **preview** at Microsoft Learn as of the #95 pass (pbi-cli's "GA
  Jan 2026" claim unconfirmed at the Microsoft source) — treat PBIR as preview
  for risk.

## Sources (primary)

- `gh api` on `data-goblin/power-bi-agentic-development` (repo metadata,
  `.claude-plugin/marketplace.json`, per-skill `SKILL.md`, README, tags/releases);
  `MinaSaad1/pbi-cli`; `NatVanG/fab-inspector`; `NatVanG/PBI-Inspector`;
  `TabularEditor/TabularEditor`; `microsoft/fabric-cli`; `microsoft/skills-for-fabric`;
  `pbi-tools/pbi-tools`.
- PyPI JSON: `pbir-cli` (0.9.27), `ms-fabric-cli`, `semantic-link-labs`.
- npm registry: `@microsoft/powerbi-report-authoring-cli` (0.1.4),
  `@microsoft/powerbi-desktop-bridge-cli` (0.1.2),
  `@microsoft/powerbi-modeling-mcp` (0.5.0-beta.11).
- Repo: `../archive/cc-otel-azure/{tools,.claude/skills/pbir-gotchas-cc-otel,CLAUDE.md}`;
  this repo `powerbi/`, `.github/powerbi/`, `.github/workflows/ci-powerbi.yml`.
- Prior research: `docs/research/dev-tooling-stack.md` (#33),
  `docs/research/pbi-cli-visual-authoring.md` (#95).
