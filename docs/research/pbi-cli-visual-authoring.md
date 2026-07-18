# Driving pbi-cli v3.11.1 to author pixel-perfect PBIR visuals

**Ticket:** #95 (wayfinder research). **Date:** 2026-07-18.
**Method:** every claim traced to a PRIMARY source — the pbi-cli GitHub repo
(`github.com/MinaSaad1/pbi-cli`, branch `master`, read via `gh api`: README,
release `v3.11.1`, and the shipped `SKILL.md`/visual-template files that Claude
actually loads), Microsoft's PBIR JSON-schemas (`github.com/microsoft/json-schemas`
under `fabric/item/report/definition`, read via `gh api`), and Microsoft Learn
(via the Learn MCP). Versions/dates were taken from the GitHub API's absolute
timestamps, not the release page's misleading relative dates. **VERIFIED** =
read at the owning source this pass; **UNVERIFIED** = not confirmed at a primary
source, or a source-vs-source conflict is flagged.

---

## TL;DR — the answers

1. **Runtime shape (the AFK-vs-HITL question):** pbi-cli's **Report layer**
   (`report`, `visual`, `filters`, `format`, `bookmarks`, `themes` command
   groups) edits the `.pbip` **PBIR JSON offline** — "No Power BI Desktop
   connection is needed." So authoring pages/visuals/positioning/binding/
   formatting/theme on `powerbi/cc-otel-report.Report` is **AFK-automatable**,
   provided we pass `--no-sync` (default behaviour closes+reopens Desktop after
   every write) and skip the optional `reload`/`preview` extras. The **Semantic
   Model layer** (`measure`, `dax`, `security-role`, …) *does* require
   `pbi connect` to a **running** Power BI Desktop (in-process TOM/ADOMD) — that
   part is **HITL / not AFK**. But we don't need it: measures already live in
   TMDL (`_Measures.tmdl`) and can be authored on disk. **Net: the #28 visual
   build is AFK-automatable through the offline Report layer; two things force
   HITL — creating new measures via pbi-cli, and drillthrough wiring (see #4).**

2. **Drillthrough is a v3.11.1 CLI gap.** The Pages skill states plainly:
   "PBIR drillthrough configuration is **not yet supported via CLI** — the CLI
   can read and report on drillthrough configuration." The Users→Session-detail
   drill must be hand-authored in `page.json` `pageBinding` (the PBIR schema
   supports it) or set once in Desktop (HITL).

3. **pbi-cli emits visualContainer `2.7.0`; our repo baseline is `2.9.0`.**
   The shipped templates declare `.../visualContainer/2.7.0/schema.json`, while
   `report.json` records `reportVersionAtImport.visual = 2.9.0`. Each PBIR file
   is ajv-validated against its **own** declared `$schema`, so mixed versions
   both pass, but expect version drift in diffs and re-validate.

---

## 1. pbi-cli authoring surface (VERIFIED, pinned to v3.11.1)

**Pin:** `pbi-cli-tool` **v3.11.1**, tag `v3.11.1`, published
**2026-05-04T18:06:02Z**, MIT (bundled Microsoft AMO/ADOMD DLLs under separate
Microsoft license). Repo default branch `master`, 418 stars. v3.11.1 itself is a
narrow fix — it teaches the *custom-visuals* skill to populate required
`pbiviz.json` metadata; the report-authoring surface below is unchanged from
v3.11.0 and the v3.10.x PBIR fixes. Requires **Windows + Python 3.10+**; install
`pipx install pbi-cli-tool` then `pbi-cli skills install`.

**What `pbi-cli skills install` registers:** **13** Claude Code skills discovered
from `src/pbi_cli/skills/*/SKILL.md`. Seven need `pbi connect` (**DAX,
Modeling, Deployment, Security, Docs, Partitions, Diagnostics**); **six are
offline Report-layer skills** — **Report, Visuals, Pages, Themes, Filters,
Custom Visuals**. Skills are auto-triggered by keywords in their YAML
`description` (e.g. the Visuals skill triggers on "add a chart", "KPI", "gauge",
"bind data", "resize visuals").

**Command → task map** (from README "All Commands" + the SKILL.md files):

| Task | Command(s) |
|---|---|
| Add page | `pbi report add-page --display-name "…" --name <n> [--width --height]` (default canvas 1280×720) |
| Add visual | `pbi visual add --page <p> --type <alias> [--name --x --y --width --height]` |
| Set position / size / z-order | `pbi visual update <v> --page <p> --x --y --width --height` (position writes `x/y/z/height/width/tabOrder`; **z / tabOrder are template placeholders set at add-time**, no dedicated `--z` flag documented — see Open items) |
| Bind fields + measures | `pbi visual bind <v> --page <p> --category/--value/--field/--row/--column/--indicator/--goal/--trend/--x/--y/--detail/--size/--legend/--max` (role→PBIR alias via ROLE_ALIASES; value/indicator/goal/max→Measure, category/row/detail→Column; `--measure` override) |
| Set visual formatting | container: `pbi visual set-container <v> --background --border-color --border-width --title`; conditional: `pbi format background-gradient|background-conditional|background-measure …` |
| Apply a report theme | `pbi report set-theme --file <theme.json>` (copies into `StaticResources/RegisteredResources/`, references it in `report.json`); preview with `pbi report diff-theme`, inspect with `pbi report get-theme` |
| Wire drillthrough | **Not supported for authoring in v3.11.1** — `report get-page` reads `page_binding`; creating it is Desktop-only or hand-JSON |
| Validate / preview | `pbi report validate`, `pbi report info`, `pbi report preview` (needs `[preview]` extra), `pbi report reload` (needs `[reload]`/pywin32) |
| Bulk / batch | `pbi visual where|bulk-bind|bulk-update|bulk-delete` (filter by `--type`/`--name-pattern`/`--x-min…--y-max`); `--no-sync` on `report`/`visual`/`filters`/`bookmarks` groups + one `pbi report reload` at the end |
| Filters | `pbi filters add-categorical|add-topn|add-relative-date|remove|clear` |
| Machine output | `--json` on every command (built for agents) |

**32 visual types** by alias (e.g. `bar`→`barChart`, `card`→`card`,
`card_visual`→`cardVisual`, `kpi`→`kpi`, `gauge`→`gauge`, `matrix`→`pivotTable`,
`table`→`tableEx`, `combo`→`lineStackedColumnComboChart`). Custom visuals
(`.pbiviz`) via `visual import-custom/list-custom/remove-custom` + a TypeScript
`powerbi-visuals-tools@^5.6.0` loop — not needed for our star-model report.

**Critical prerequisite (VERIFIED):** `visual bind` only *writes a field
reference*; it does **not** create the measure. Every `--value`/`--field` must
already exist in the TMDL, **case-sensitively** (`"Fact_Sales"` ≠ `"fact_sales"`,
`"Total Revenue"` ≠ `"Total_Revenue"`), or Desktop shows a broken-field error.
For us: bind only to measures/columns that exist in `cc-otel-report.SemanticModel`.

---

## 2. Runtime shape — offline PBIR edit vs live TOM (VERIFIED, decisive)

- **Report layer = offline file editing.** Every Report/Visuals/Pages/Themes/
  Filters SKILL.md repeats "No Power BI Desktop connection is needed — these
  commands operate directly on JSON files." The README architecture section:
  "Report layer — Reads and writes PBIR (Enhanced Report Format) JSON files
  directly. No connection needed. Works with `.pbip` projects." **→ AFK-safe.**
- **Auto-sync is the AFK trap.** By default each write command "closes Desktop
  with save and reopens the `.pbip`." On a headless/AFK runner there is no
  Desktop, so **always pass `--no-sync`** (available on `report`, `visual`,
  `filters`, `bookmarks`) and do **not** install the `[reload]`/`[preview]`
  extras. Batch all edits, then `pbi report validate` (never `reload`).
- **Semantic Model layer = live Desktop required.** `pbi connect` opens an
  in-process .NET TOM/ADOMD connection to a **running** Desktop with the model
  loaded. Anything under `measure`, `dax`, `security-role`, `partition`, etc.
  needs it → **HITL**. We avoid this: the #27 model was authored in TMDL, and
  new measures/thresholds land in `_Measures.tmdl` on disk (then reopen Desktop
  once to pick them up — Desktop reads TMDL only on open).
- **Consequence for #28:** the visual build (pages, visuals, positioning,
  binding to *existing* measures, container + conditional formatting, theme) is
  fully AFK through the offline Report layer + `ajv`/`fab-inspector` validation.
  The only forced HITL steps are (a) authoring any **new** measure the visuals
  need, and (b) **drillthrough** wiring.

---

## 3. PBIR visual JSON structure (VERIFIED against microsoft/json-schemas)

**Folder shape** (Learn `projects-report#pbir-format`): `definition/pages/
<pageName>/page.json` + `visuals/<visualName>/visual.json` (+ optional
`mobile.json`); page order in `pages/pages.json`; report-wide settings/theme in
`definition/report.json`; `version.json` gates which files load. Our canvas is
already **1280×720** (`page.json`: `width:1280, height:720, displayOption:
FitToPage`).

**visualContainer positioning model** (schema `visualContainer/2.9.0`, our repo
baseline; `$schema` const, `additionalProperties:false`). Required top-level:
`$schema`, `name` (unique per page, **maxLength 50**), `position`. Also:
`visual` (→ `visualConfiguration/2.3.0`), `visualGroup` (grouping container,
`groupMode` ScaleMode/ScrollMode), `parentGroupName`, `filterConfig`
(→ `filterConfiguration/1.3.0`), `isHidden`, `annotations`.

`VisualContainerPosition` (required `x`, `y`, `height`, `width`; optional `z`,
`tabOrder`, `angle`):
- `x` / `y` — left/top edge in px, `0 ≤ x`, `x + width ≤ page width` (same for y/height).
- `z` — **stacking order**; higher z draws on top.
- `tabOrder` — keyboard tab navigation order.
- `angle` — rotation.

**pbi-cli's emitted `visual.json`** (from the shipped `card.json`/`kpi.json`
templates — note **schema 2.7.0**, older than our 2.9.0 baseline):
```json
{
  "$schema": ".../visualContainer/2.7.0/schema.json",
  "name": "__VISUAL_NAME__",
  "position": { "x": …, "y": …, "z": …, "height": …, "width": …, "tabOrder": … },
  "visual": {
    "visualType": "kpi",
    "query": { "queryState": {
      "Indicator": { "projections": [] },
      "Goal":      { "projections": [] },
      "TrendLine": { "projections": [] } } },
    "drillFilterOtherVisuals": true
  }
}
```
`visual bind` fills the role `projections[]` (`Values` for a card, `Indicator/
Goal/TrendLine` for a KPI, etc.) with Measure/Column references — this is the
field-binding mechanism.

**Conditional formatting** (for the freshness KPI card amber/red) — three
`pbi format` verbs, all offline:
- `background-measure <v> --page <p> --table <t> --measure "<DAX color measure>"`
  — a DAX measure returns the hex; **best fit for us**: `_Measures.tmdl` already
  holds `Freshness Amber/Red Hours` thresholds, so add a `Freshness Color`
  measure returning `#D13438`/`#F7A600`/`#107C10` and drive the card background.
- `background-conditional … --column <c> --value "<v>" --color "<hex>"` — rule by value.
- `background-gradient … --column <c> --min-color --max-color` — min→max scale
  (the mechanism for the **time-of-day heatmap**: a matrix with a gradient over
  the count measure; PBI has no native heatmap visual).
  Under the hood these write `formattingObjectDefinitions/1.5.0` selectors into
  the visual's `objects`. **UNVERIFIED:** exact emitted JSON not inspected this pass.

**Drillthrough config** lives in `page.json` `pageBinding` (drillthrough/tooltip
pages; name is a GUID by default post-June-2024). v3.11.1 reads it via
`report get-page` (`page_type: "Drillthrough"`, `page_binding: {...}`) but
**cannot author it** — hand-write `pageBinding` per the `page/2.1.0` schema, or
configure once in Desktop.

---

## 4. Layout best practices (VERIFIED against Microsoft Learn)

- **Grid & alignment:** use gridlines/snap-to-grid for precise alignment;
  consistent alignment reads as professional
  (`power-bi-reports-overview#report-layout-and-design`). On a 1280×720 canvas,
  author on a fixed px grid (e.g. 8/16-px gutters) and keep KPI cards a uniform
  size — `visual bulk-update --type kpi --width … --height …` enforces it.
- **Group related visuals** to move/resize/layer as a unit — maps to PBIR
  `visualGroup` containers (z-order and background travel with the group).
- **KPI-card pattern:** keep visuals simple; break busy visuals apart but keep
  the page's visual count low (fewer visuals = clearer *and* faster). Uniform
  title font/size and consistent slicer position across pages.
- **Colour / accessibility (WCAG):** text-vs-background contrast ≥ **4.5:1**
  (WCAG 2.1 §1.4.3); never use colour as the *only* signal — pair it with text
  or an icon (directly relevant to the freshness KPI: amber/red **plus** a label
  like "3.2 h stale"). Avoid red/green together for colour-vision deficiency —
  our star-model family colours should be a colourblind-safe categorical set.
- **Fixed per-model-family colours:** set them once in the report theme
  `dataColors` (6–12 colours) so `dim_model` families map to stable colours
  report-wide; override a single series only where needed. Theme is applied via
  `report set-theme` from our `branding/design-tokens.json`. Avoid the theme
  properties the Themes skill flags as schema-invalid (`border.radius`, top-level
  `page`, `dropShadow.position`) — they silently break Desktop load.
- **Time-of-day heatmap:** no native heatmap visual — build a `matrix`
  (`pivotTable`) of hour-of-day × day with `background-gradient` on the count
  measure (sequential, single-hue for accessibility).
- **Drillthrough design** (`guidance/report-drillthrough`): match the drill page
  to the report theme; **hide** the drillthrough page from nav; keep the
  auto-added Back button; avoid visuals that go BLANK/error under the drill
  filter. Fits our Users → Session-detail drill.

**Adjacent primary option (not required, noted for completeness):** Microsoft
ships its own agentic **Power BI Report Design** + **Report Authoring** skills
in the *Skills for Fabric* marketplace (`github.com/microsoft/skills-for-fabric`,
**preview**). Design skill emits a design brief; Authoring skill writes the PBIR
files. Overlaps pbi-cli's report layer; a first-party alternative to weigh if
pbi-cli's drillthrough/z-order gaps bite.

---

## 5. Validation loop — authored output vs our CI triad (VERIFIED tooling, from `docs/research/dev-tooling-stack.md`)

Run all three locally before opening Desktop; they mirror the POC
`validate-all.ps1`:

1. **ajv PBIR schema validation** — validate every authored `*.json` against the
   Microsoft schema its `$schema` points at. All the versions we touch are
   published in `microsoft/json-schemas`: `visualContainer` up to **2.9.0**
   (also 2.7.0, what pbi-cli writes), `page` up to **2.1.0**, `report` **3.3.0**.
   Because pbi-cli emits 2.7.0 and the repo baseline is 2.9.0, keep the ajv schema
   cache covering **both**; each file validates against its own declared version.
2. **fab-inspector v3.4.0** — declarative JSON rules over the PBIR definition
   (`-formats GitHub` in CI). Carry the POC `cc-otel-rules.json` forward; add
   rules for our conventions (canvas 1280×720, KPI-card uniform size, no invalid
   theme keys).
3. **TE2 `-A` BPA v2.28.0** — Best-Practice Analyzer over the **semantic model**
   (windows-latest), `TabularEditor.exe <model> -A <rules>`. Validates the model
   the visuals bind to, not the visuals themselves.

Plus pbi-cli's own gate: **`pbi report validate`** (required files present, all
JSON parses incl. trailing-comma catch, `$schema` consistency, `pages.json`
references resolve). Cheap first pass before ajv/fab-inspector.

---

## Open / UNVERIFIED items

- **Z-order / tabOrder authoring flag.** Templates carry `z`/`tabOrder`
  placeholders and `visual add` sets `position`, but no explicit `--z`/
  `--tab-order` flag is documented in the Visuals SKILL.md. Stacking may only be
  settable via `visual update` position or by editing `visual.json`. **Verify
  against `pbi visual add/update --help` on the installed CLI.**
- **Exact conditional-formatting JSON** emitted by `format background-measure/
  gradient/conditional` (the `objects`/`formattingObjectDefinitions` shape) was
  not inspected — confirm it validates against `visualConfiguration/2.3.0` +
  `formattingObjectDefinitions/1.5.0` before relying on the amber/red card.
- **PBIR GA vs preview — source conflict.** pbi-cli's Report SKILL.md asserts
  "PBIR is GA as of January 2026 and the default format in Desktop since March
  2026." Microsoft **Learn still labels PBIR "currently in preview"** as fetched
  this pass (`projects-report#pbir-format`, considerations list). Treat PBIR as
  **preview** for risk purposes until Learn says otherwise; the GA claim is
  **UNVERIFIED** at the Microsoft source.
- **Semantic-model values persisting into visual.json.** Learn warns filter/
  slicer selections persist as data in `visual.json`; irrelevant for a fresh
  build but relevant if we ever copy visuals from a data-loaded report.
- **pbi-cli on a non-Windows CI runner.** It is Windows-only and TOM-dependent
  for the model layer; the offline Report layer is pure-Python file I/O but was
  not tested on Linux this pass — authoring is a **dev-machine (Windows)** step,
  not a CI step (consistent with the dev-tooling verdict: "adopt for local
  authoring, not CI").

## Sources (primary)

- pbi-cli repo `master` via `gh api`: `/readme`, `/releases/tags/v3.11.1`,
  `/contents/src/pbi_cli/skills/{power-bi-report,visuals,pages,themes}/SKILL.md`,
  `/contents/src/pbi_cli/templates/visuals/{card,kpi}.json`.
- microsoft/json-schemas via `gh api`:
  `fabric/item/report/definition/{visualContainer/2.9.0,page,report,…}`.
- Microsoft Learn (Learn MCP): `power-bi/developer/projects/projects-report`,
  `create-reports/power-bi-reports-overview`,
  `create-reports/desktop-accessibility-creating-reports`,
  `create-reports/desktop-drillthrough`, `guidance/report-drillthrough`,
  `developer/agentic/power-bi-report-design-skill-overview`.
- Repo: `docs/research/dev-tooling-stack.md` (validation-triad versions),
  `powerbi/cc-otel-report.Report/definition/*` (current PBIR baseline),
  `powerbi/README.md` (model shape).
