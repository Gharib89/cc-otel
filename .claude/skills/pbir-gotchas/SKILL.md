---
name: pbir-gotchas
description: "PBIR (Power BI Enhanced Report) format traps hit authoring the cc-otel report on disk. Use when editing visuals under `powerbi/cc-otel-report.Report/` — drillthrough filters, cards, slicers, action buttons, themes — or when ajv `$schema` validation fails. Complements the data-goblin `pbir-format` skill with traps it doesn't cover."
---

# PBIR gotchas — cc-otel

Hard-won lessons authoring `powerbi/cc-otel-report.Report/`. Most cost >=20 min of debugging. Check this before editing PBIR `visual.json` files. These are PBIR **format** traps and stay valid across an IA redesign — they are about the JSON, not any one report's page layout.

For general PBIR format reference, defer to the `pbir-format` skill (data-goblin). This file only documents traps **not** covered there.

## Statically checkable traps are enforced, not documented

`.github/powerbi/gotchas-lint.mjs` (a `validate.ps1` / `ci-powerbi` leg, #135) fails the gate on the machine-checkable traps: Drillthrough-as-filter-type (1), `visualLink` under `objects` (4), folder naming (7), multi-projection cards (10), theme subtype cascade (11), `shape` fill (13), the actionButton show/selector contract + state ids (14), `textbox` visualLink (16), thin actionButton fill (17), theme `visualStyles` property shapes (18), `wordWrap` inside `labels` (19), and a column projected as a `Measure` (22, the only model-aware rule — it parses the sibling `.SemanticModel` TMDL to tell a real measure from a wrongly-wrapped column; renders as a hard field error on live data that every other leg passes silently). Fix what a lint message names — the rule text travels with it. Below are only the traps a linter can't catch, keeping their original numbers.

## 1. Drillthrough — the runtime half

The lint catches `"type": "Drillthrough"` in `filterConfig` (only `pageBinding` takes that type; the filter is `Passthrough`). pbi-cli does **not** author drillthrough (see the tooling doc) — hand-write it. The working on-disk shape (#125, drill verified live in Desktop with **no** Desktop-side wiring needed — an earlier version of this trap wrongly claimed the field must also be added in Desktop's UI):

```json
"visibility": "HiddenInViewMode",
"pageBinding": {
  "name": "pb_<page>", "type": "Drillthrough",
  "parameters": [{ "name": "p_<page>", "boundFilter": "flt_drill_<page>",
                   "fieldExpr": { "Column": { "Expression": { "SourceRef": { "Entity": "<table>" } }, "Property": "<column>" } } }]
},
"filterConfig": { "filters": [{ "name": "flt_drill_<page>", "field": { ...same column... },
                                "type": "Passthrough", "howCreated": "Drillthrough" }] }
```

Right-click → Drill through then appears on any visual projecting that column, report-wide — no source-visual edits. Mind relationship direction on the target page: a drill filter lands on the bound table only; facts behind **inactive** relationships need `USERELATIONSHIP` measures (see the `Session *` measures).

## 21. Measure-only bar charts fail the conformance gate — give them a disconnected axis

`clusteredBarChart`/`clusteredColumnChart` with only `Y` measure projections and no `Category` renders fine in Desktop but fails the (blocking) MS conformance CLI: `PBIR_ROLE_REQUIRED_MISSING`. When the "categories" are N measures living on different tables (the five ecosystem bridges), add a disconnected N-row calculated table (`DATATABLE`, no relationships) plus one `SWITCH ( SELECTEDVALUE (...) )` measure, and bind that as Category + Y. Bonus: real axis labels instead of a color legend.

## 2. `card` visual needs a Measure, not a Column

Binding a Column directly to a `card` visual renders blank.

Fix: wrap the column in a measure.

```dax
'Selected User' = SELECTEDVALUE(Users[user_id])
```

Then bind the measure. Works.

## 3. `slicer` mode literals

`data.mode.expr.Literal.Value`:
- Text slicer dropdown -> `'Dropdown'`
- Date slicer range -> `'Between'`

These are literal strings with single quotes inside the JSON string value, e.g. `"Value": "'Dropdown'"`. Easy to set the wrong one and end up with a list slicer where a dropdown was wanted.

## 5. Sort syntax inside `visualConfiguration`

```json
"query": {
  "queryState": { ... },
  "sortDefinition": {
    "sort": [
      { "field": {...measure or column...}, "direction": "Descending" }
    ]
  }
}
```

`direction`: `"Ascending"` or `"Descending"`.

## 6. Matrix `HierarchyLevel` on a datetime column

Requires auto-datetime hierarchy enabled on the column. Off by default for imported tables. Either:
- Enable auto-datetime hierarchy on the column in TMDL, OR
- Define a calculated column: `'Started Hour' = HOUR([started_at])` and bind that

## 7. Renaming page folders: close Desktop first

Folder naming itself is linted. The runtime trap: Desktop must be **CLOSED** before renaming page folders. Desktop holds an open file handle on the open `.pbip` and rename will fail or corrupt state.

## 8. Unpublished `$schema` version -> ajv fetch failure

The repo validator (`.github/powerbi/validate-pbir.mjs`, run via `validate.ps1`) fetches the **exact** `$schema` URL each file declares over HTTP and validates against it — there is no version-fallback map. Desktop and pbi-cli sometimes emit different `visualContainer` schema versions (baseline here is `2.9.0`; pbi-cli emits `2.7.0` — both valid against their own declared `$schema`).

The trap: if Desktop writes a `$schema` URL for a version Microsoft hasn't published yet on `developer.microsoft.com`, the ajv fetch returns HTTP 404. As of #195 the validator treats an unreachable schema (404 or offline) as a **skip with a warning** (`schema unreachable, validation skipped: ...`), matching the MS conformance CLI, so the gate stays green and no hand-reverting of Desktop's `$schema` bump is needed. Genuinely invalid PBIR against a *reachable* schema still fails. Aligning the `$schema` line to the nearest **published** version is now optional cleanup, not a gate requirement.

## 9. `theme.json` transparency overrides per-visual transparency

`actionButton.fill.transparency: 100` in the shared theme makes every action button transparent — even visuals that explicitly set `transparency: 0D` in `visualContainerObjects.fill`.

Theme wins when both target the same property. Fix theme first, then trust per-visual.

```json
// theme.json
"actionButton": {
  "*": {
    "fill": [{ "transparency": 0 }]   // NOT 100
  }
}
```

## 12. Tables/matrices need per-visual `title.text` — theme alone insufficient

Setting `tableEx.title.show: true` in the theme does NOT make tables render a title strip. You also need a per-visual block:

```json
"visualContainerObjects": {
  "title": [
    {
      "properties": {
        "show": { "expr": { "Literal": { "Value": "true" } } },
        "text": { "expr": { "Literal": { "Value": "'Cost by Model and Effort'" } } },
        "background": { "solid": { "color": { "expr": { "Literal": { "Value": "'#1a1a1a'" } } } } },
        "fontColor": { "solid": { "color": { "expr": { "Literal": { "Value": "'#ffffff'" } } } } }
      }
    }
  ]
}
```

Theme defines style. Per-visual carries the string.

## 13/17. Solid fills: which primitive actually renders

The lint bans the two dead ends (`shape` `objects.fill`, actionButton fill under ~4px height). What to use instead:

- **Panels >=~10px tall** (nav backdrop, header strip): `actionButton` with chrome killed — `icon.shapeType 'blank'`, `outline.show false`, `objects.fill` show+fillColor (with `selector: {"id": "default"}` on the styling entry), and `visualContainerObjects` background/border/visualHeader/dropShadow all off. Copy a Desktop-emitted one rather than hand-building.
- **Thin bars 1-3px** (hairlines, nav underlines, dividers): `shape` with **`visualContainerObjects.background`** — the container background renders even though `objects.fill` doesn't:

```json
{
  "visualType": "shape",
  "objects": {
    "shape": [{ "properties": { "tileShape": { "expr": { "Literal": { "Value": "'rectangle'" } } } } }],
    "fill": [{ "properties": { "show": { "expr": { "Literal": { "Value": "false" } } } } }],
    "outline": [{ "properties": { "show": { "expr": { "Literal": { "Value": "false" } } } } }]
  },
  "visualContainerObjects": {
    "background": [{ "properties": {
      "show": { "expr": { "Literal": { "Value": "true" } } },
      "color": { "solid": { "color": { "expr": { "Literal": { "Value": "'#0E2841'" } } } } },
      "transparency": { "expr": { "Literal": { "Value": "0D" } } }
    } }]
  }
}
```

Reserve `shape` for lines/dividers (where only the outline matters) and thin background bars.

## 15. `pageNavigator` shows every page unless hidden

The built-in `pageNavigator` enumerates all pages in `pages.json` order, including drillthrough targets. To hide a page from nav:

```json
"objects": {
  "pages": [
    {
      "properties": {
        "showPage": { "expr": { "Literal": { "Value": "false" } } }
      },
      "selector": { "data": [{ "scopeId": { "Literal": { "Value": "'<page-name>'" } } }] }
    }
  ]
}
```

`<page-name>` matches the page folder name. One selector entry per hidden page.

## 19. `labelPrecision` loses to the measure formatString

`labels.labelPrecision` (an `L`-typed literal, e.g. `"0L"`) is **ignored when the measure's model formatString pins decimals** — a `0.0%` formatString renders `75.0%` no matter what the visual says. Fix the decimals in TMDL (`formatString: 0%`), which is a model change: `reload` won't apply it, reopen the pbip. (The `wordWrap`-placement half of this gotcha is linted.)

## 20. Visual Top-N (`VisualTopN`) authored on disk is not applied

A visual-level Top-N filter hand-written into `filterConfig` is **schema-valid but silently ignored** on load — the visual renders every category, scrolling, as if no filter existed. Verified against `ci-powerbi`: ajv (semanticQuery `1.4.0`) requires `Condition.VisualTopN` to be exactly `{ "ItemCount": <n> }` (no `Expression`/`OrderBy`/`Count`/`IsAscending` — that richer shape is legacy report.json, and ajv rejects it), with the ordering measure in the sibling `Where[].Target`. Both the `ItemCount` form and the legacy form failed to limit rows even after a full pbip reopen (not just bridge `reload`), matching the documented caveat that PBIR visual filters activate only after the filter pane is expanded in Desktop.

Consequence: you cannot cap a high-cardinality bar to "top N" purely on disk. Options: leave the visual sorted-descending and scrollable (top-first, standard interactive UX); author the Top-N in Desktop's Filters pane (Desktop-persisted filters do render) and commit the emitted JSON; or filter on an explicit `RANKX` measure via a `Comparison` condition (column categorical + comparison filters *are* honored on disk — see the cohort filters — though measure-comparison reliability is unproven here).

## 23. Adding `altText` blindly duplicates a pre-existing `general` and crashes fab-inspector

`altText` lives at `visualContainerObjects.general[].properties.altText`. A scripted pass that *prepends* a fresh `"general": [...]` block to every data visual's `visualContainerObjects` breaks on any visual that **already has** a `general` object there: the file ends up with two `"general"` keys in the same object. Python `json.loads` silently keeps the last (so a JSON round-trip "passes"), but fab-inspector's strict .NET parser throws and the whole rule aborts: `::error:: Rule "Reduce the number of objects within visuals" - Part "page.json" execution failed. Inner exception: An item with the same key has already been added. Key: general`. With `-formats GitHub` that `::error` is a non-zero exit — a **blocking** `ci-powerbi` red, not a warning. The crash names the key, never the offending file, so it reads like a tool bug; it isn't.

Before inserting, check each visual for an existing `visualContainerObjects.general` and **merge into it** (or skip — it already carries alt) rather than adding a second key. In this report only `pg_capacity/cht_util_heatmap` (pivotTable) shipped with hand-authored alt, so it was the lone landmine across a 110-visual pass. Note the two `general` bags are independent: a `textbox` carrying paragraphs in `objects.general` takes a new `visualContainerObjects.general` alt cleanly — fab-inspector does **not** merge `objects` and `visualContainerObjects`, so only a duplicate **within** `visualContainerObjects` collides.

## Validation flow

Run `pwsh .github/powerbi/validate.ps1` before commit — it mirrors the `ci-powerbi` gate locally (ajv schema, pbir-gotchas lint, fab-inspector rules, Tabular Editor 2 BPA, MS conformance CLI). Setup, the tooling roster, and the exit-code contract: `docs/agents/powerbi-tooling.md`.
