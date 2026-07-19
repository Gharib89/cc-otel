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
    "icon": [{ "properties": { "shapeType": { "expr": { "Literal": { "Value": "'blank'" } } } }, "selector": { "id": "default" } }],
    "outline": [{ "properties": { "show": { "expr": { "Literal": { "Value": "false" } } } } }],
    "fill": [
      { "properties": { "show": { "expr": { "Literal": { "Value": "true" } } } } },
      {
        "properties": {
          "fillColor": { "solid": { "color": { "expr": { "Literal": { "Value": "'#1a1a1a'" } } } } },
          "transparency": { "expr": { "Literal": { "Value": "0D" } } }
        },
        "selector": { "id": "default" }
      }
    ]
  },
  "visualContainerObjects": {
    "background": [{ "properties": { "show": { "expr": { "Literal": { "Value": "false" } } } } }],
    "border": [{ "properties": { "show": { "expr": { "Literal": { "Value": "false" } } } } }],
    "visualHeader": [{ "properties": { "show": { "expr": { "Literal": { "Value": "false" } } } } }],
    "dropShadow": [{ "properties": { "show": { "expr": { "Literal": { "Value": "false" } } } } }]
  }
}
```

`fill` (like all button formatting) lives under **`objects`**, not `visualContainerObjects` — the 2.9.0 schema rejects `visualContainerObjects.fill` (`must NOT have additional properties`), and the MS conformance CLI names the fix. Reserve `shape` for lines/dividers (where only the outline matters).

## 14. `actionButton` formatting: `show` goes selector-less; styling goes under `selector: { "id": "default" }`

Two-part contract, screenshot-verified on the pg_exec nav build (#119). Desktop emits each button formatting object (`text`, `fill`, `outline`, `icon`) as **two entries**:

- the **`show` toggle in its own entry with NO selector** (it is a card-level switch), and
- the **per-state styling** (`text`, `fontColor`, `fontSize`, `fillColor`, …) in a second entry with `"selector": { "id": "default" }`.

```json
"text": [
  { "properties": { "show": { "expr": { "Literal": { "Value": "true" } } } } },
  {
    "properties": {
      "text": { "expr": { "Literal": { "Value": "'Overview'" } } },
      "fontColor": { "solid": { "color": { "expr": { "Literal": { "Value": "'#ffffff'" } } } } },
      "fontSize": { "expr": { "Literal": { "Value": "10D" } } }
    },
    "selector": { "id": "default" }
  }
]
```

Valid state IDs: `default`, `hover`, `selected`, `disabled`, `pressed`. **Both directions fail silently**: styling without the selector is ignored, and putting `show` *inside* the selector entry disables the whole formatting bag — the button renders as an empty placeholder outline with no fill and no text. ajv, fab-inspector, and the MS conformance CLI all pass either way; only a screenshot catches it. Reference: `pbir-format` skill's `examples/visuals/formatted/actionButton.json` (Desktop-emitted).

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

## 17. Thin bars (hairlines, underlines): `actionButton` fill doesn't render below ~4px height

The gotcha-13 actionButton-fill pattern silently renders nothing at 1-3px heights (nav underlines, divider rules). For thin solid bars use `shape` with **`visualContainerObjects.background`** — the container background renders even though `objects.fill` doesn't (gotcha 13):

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

Keep actionButton fill for panels >=~10px tall (gotcha 13's nav backdrop case).

## 18. Theme `visualStyles` property shapes differ from textClasses and PBIR literals

Two traps writing `visualStyles` into a theme JSON (both named precisely by the repo validator):

- Colors are **objects**, not hex strings: `"fontColor": {"solid": {"color": "#FFFFFF"}}` — a bare `"#FFFFFF"` fails `must be object`.
- The font property is **`fontFamily`** inside `visualStyles` cards (title, subTitle, …); `fontFace` is only valid inside `textClasses` — the conformance CLI flags it `PBIR_THEME_VISUAL_PROP_UNKNOWN`.

`subTitle` is a valid theme/visual card (gray line under a title band) even though Desktop's base themes never emit it.

## 19. Card `wordWrap` is its own formatting object; `labelPrecision` loses to the measure formatString

- `wordWrap` on a `card` is a separate object — `"wordWrap": [{"properties": {"show": ...}}]` — not a `labels` property (`PBIR_FORMATTING_PROP_UNKNOWN` otherwise).
- `labels.labelPrecision` (an `L`-typed literal, e.g. `"0L"`) is **ignored when the measure's model formatString pins decimals** — a `0.0%` formatString renders `75.0%` no matter what the visual says. Fix the decimals in TMDL (`formatString: 0%`), which is a model change: `reload` won't apply it, reopen the pbip.

## Validation flow

Run `pwsh .github/powerbi/validate.ps1` before commit — it mirrors the `ci-powerbi` gate locally (ajv schema, fab-inspector rules, Tabular Editor 2 BPA). Setup, the tooling roster, and the exit-code contract: `docs/agents/powerbi-tooling.md`.
