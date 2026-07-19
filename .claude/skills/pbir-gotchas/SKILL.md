---
name: pbir-gotchas
description: "PBIR (Power BI Enhanced Report) format traps hit authoring the cc-otel report on disk. Use when editing visuals under `powerbi/cc-otel-report.Report/` — drillthrough filters, cards, slicers, action buttons, themes — or when ajv `$schema` validation fails. Complements the data-goblin `pbir-format` skill with traps it doesn't cover."
---

# PBIR gotchas — cc-otel

Hard-won lessons authoring `powerbi/cc-otel-report.Report/`. Most cost >=20 min of debugging. Check this before editing PBIR `visual.json` files. These are PBIR **format** traps and stay valid across an IA redesign — they are about the JSON, not any one report's page layout.

For general PBIR format reference, defer to the `pbir-format` skill (data-goblin). This file only documents traps **not** covered there.

## 1. Drillthrough filter type — most painful

On a drillthrough target page (`pages/<page>/page.json`):

```json
"pageBinding": { "type": "Drillthrough" },          // CORRECT — valid BindingType enum
"filterConfig": {
  "filters": [
    { "type": "Passthrough", ... }                  // CORRECT
    // NOT { "type": "Drillthrough" } — that fails schema validation silently
  ]
}
```

Filter `type` enum: `Categorical | Range | Advanced | Passthrough | TopN | Include | Exclude | RelativeDate | Tuple | RelativeTime | VisualTopN`.

`Drillthrough` is **not** a valid filter type — only a `pageBinding` type. Mixing them up was the worst trap of the build.

**Also:** schema correctness is necessary but not sufficient. The user must add the same column to the page's "Drill through" field in Desktop UI for filter propagation to fire at runtime. Data model awareness of the filter slot isn't enough. pbi-cli does **not** author drillthrough (see the tooling doc) — hand-write `pageBinding` or set it once in Desktop.

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

## 4. `actionButton` (back-button) PBIR canonical shape

Don't put the link config under `objects.visualLink` — it has to go under **`visualContainerObjects.visualLink`**.

```json
{
  "name": "...",
  "visualType": "actionButton",
  "objects": {
    "icon": [
      { "properties": { "shapeType": "'back'" } }
    ]
  },
  "visualContainerObjects": {           // NOT objects
    "visualLink": [
      { "properties": { "type": "'Back'" } }
    ]
  }
}
```

Reference template: any Desktop-emitted `actionButton` under `powerbi/cc-otel-report.Report/` — Desktop writes this shape correctly; copy from a verified one rather than hand-building.

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

## 7. PBIR file/folder naming

Folder names: `[a-zA-Z0-9_-]+`. No dots, spaces, or special chars. Desktop emits this convention.

**Critical:** Desktop must be **CLOSED** before renaming page folders. Desktop holds an open file handle on the open `.pbip` and rename will fail or corrupt state.

## 8. Unpublished `$schema` version -> ajv fetch failure

The repo validator (`.github/powerbi/validate-pbir.mjs`, run via `validate.ps1`) fetches the **exact** `$schema` URL each file declares over HTTP and validates against it — there is no version-fallback map. Desktop and pbi-cli sometimes emit different `visualContainer` schema versions (baseline here is `2.9.0`; pbi-cli emits `2.7.0` — both valid against their own declared `$schema`).

The trap: if Desktop writes a `$schema` URL for a version Microsoft hasn't published yet on `developer.microsoft.com`, the ajv fetch returns HTTP 404 and the gate fails with `fetch ... -> HTTP 404` (not a rule violation). Fix by aligning that file's `$schema` line to the nearest **published** version.

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

## 10. `card` visualType renders one projection only

Two `Values.projections` entries on a `card` -> Power BI shows "See details" error icon, not the second measure.

Use multi-row card (`multiRowCard`) when you need two measures stacked, or split into two `card` visuals.

## 11. Theme `visualStyles` don't cascade across chart subtypes

`barChart` style doesn't apply to `clusteredBarChart`; `columnChart` doesn't apply to `clusteredColumnChart`; `matrix` is separate from `pivotTable`. Each is its own `visualStyles.<type>` entry.

Mirror parent style into every subtype Desktop emits.

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

## 13. `shape` `fill` doesn't render in current Desktop build

Shape visuals (`visualType: "shape"`) with `fill.fillColor` set produce only the outline — no solid fill. Workaround for solid dark panels (nav backdrop, header strip): use `actionButton` with chrome killed.

```json
{
  "visualType": "actionButton",
  "objects": {
    "icon": [{ "properties": { "shapeType": { "expr": { "Literal": { "Value": "'blank'" } } } } }]
  },
  "visualContainerObjects": {
    "background": [{ "properties": { "show": { "expr": { "Literal": { "Value": "false" } } } } }],
    "border": [{ "properties": { "show": { "expr": { "Literal": { "Value": "false" } } } } }],
    "visualHeader": [{ "properties": { "show": { "expr": { "Literal": { "Value": "false" } } } } }],
    "dropShadow": [{ "properties": { "show": { "expr": { "Literal": { "Value": "false" } } } } }],
    "fill": [{
      "properties": {
        "show": { "expr": { "Literal": { "Value": "true" } } },
        "fillColor": { "solid": { "color": { "expr": { "Literal": { "Value": "'#1a1a1a'" } } } } },
        "transparency": { "expr": { "Literal": { "Value": "0D" } } }
      },
      "selector": { "id": "default" }
    }]
  }
}
```

Reserve `shape` for lines/dividers (where only the outline matters).

## 14. `actionButton` state properties need `selector: { "id": "default" }`

Per-state properties (`text`, `fill`, `outline`, `icon` color) on `actionButton` silently no-op unless the `properties` object carries a `selector` indicating which state it applies to:

```json
"text": [
  {
    "properties": {
      "text": { "expr": { "Literal": { "Value": "'Overview'" } } },
      "fontColor": { "solid": { "color": { "expr": { "Literal": { "Value": "'#ffffff'" } } } } }
    },
    "selector": { "id": "default" }     // REQUIRED
  }
]
```

Valid state IDs: `default`, `hover`, `selected`, `disabled`, `pressed`. Missing selector = property silently ignored at render time. ajv passes, fab-inspector passes, visual stays blank.

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

## 16. `textbox` has no `visualLink`

Only `actionButton` and `pageNavigator` carry `visualContainerObjects.visualLink`. Using `textbox` as a nav button = clickable area exists in JSON but Desktop renders it as static text.

Nav primitives -> `actionButton` (single target) or `pageNavigator` (multi-page strip). Decoration -> `shape` (lines/dividers) or `textbox` (static labels).

## Validation flow

Run `pwsh .github/powerbi/validate.ps1` before commit — it mirrors the `ci-powerbi` gate locally (ajv schema, fab-inspector rules, Tabular Editor 2 BPA). Setup, the tooling roster, and the exit-code contract: `docs/agents/powerbi-tooling.md`.
