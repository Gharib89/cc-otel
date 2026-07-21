# Power BI Report Best Practices Applied to the cc-otel Report

**Date:** 2026-07-21

**Research ticket:** #155 (parent map #153). AFK survey — it decides nothing;
findings feed the map's spec-sharpening. Implementation lands under later
`ready-for-agent` tickets.

**Research question:** Assess current Power BI report-design and semantic-model
best practices (layout & visual hierarchy, KPI/card design, chart selection, DAX
time-intelligence patterns, model performance, accessibility) against the actual
8-page cc-otel report, and produce a prioritized list of concrete, applicable
improvements. **Theme and colors are out of scope** — branding is settled (#153).

**Method:** The real report was read first — all 8 PBIR pages under
`powerbi/cc-otel-report.Report/definition/pages/` (210 visuals) and the full
semantic model under `powerbi/cc-otel-report.SemanticModel/definition/`
(~70 measures in `tables/_Measures.tmdl`, relationships, RLS, partitions) — then
assessed against primary sources. Generic advice that does not apply to this
report is omitted. Items already decided on map #153 (time-intel redesign,
top-users title fix) are not re-recommended; where relevant the concrete
best-practice pattern that implements the decision is given instead.

**Primary sources used (all claims trace to one of these):**

- [Design Power BI reports for accessibility (Microsoft Learn)](https://learn.microsoft.com/en-us/power-bi/create-reports/desktop-accessibility-creating-reports)
  — fetched 2026-07-21; the author-side accessibility checklist. Cited as **[MS-A11y]**.
- [Standard time-related calculations (DAX Patterns, SQLBI)](https://www.daxpatterns.com/standard-time-related-calculations/)
  — date-table prerequisites, PP/rolling patterns. Cited as **[DAX-Patterns]**.
- [Understanding DATEADD parameters with calendar-based time intelligence (SQLBI)](https://www.sqlbi.com/articles/understanding-dateadd-parameters-with-calendar-based-time-intelligence/)
  — DATEADD shifts the current filter context; contiguous-selection requirement. Cited as **[SQLBI-DATEADD]**.
- [Comparing with previous selected time period in DAX (SQLBI)](https://www.sqlbi.com/articles/comparing-with-previous-selected-time-period-in-dax/)
  — ALLSELECTED-based previous-in-selection pattern (non-contiguous selections). Cited as **[SQLBI-PrevSel]**.
- [Troubleshoot report performance / optimization guidance (Microsoft Learn)](https://learn.microsoft.com/en-us/power-bi/guidance/report-performance-troubleshoot)
  and [Optimization guide for Power BI](https://learn.microsoft.com/en-us/power-bi/guidance/power-bi-optimization)
  — limit per-visual data with restrictive/Top-N filters; Performance Analyzer loop. Cited as **[MS-Perf]**.
- **`reports:pbi-report-design` skill** (data-goblin Power BI agentic-development
  plugin, v26.25 — the design canon this repo already routes report-design
  judgment to per CLAUDE.md): 3-30-300 detail gradient, KPI target/gap/trend
  rule, chart-selection and anti-pattern catalog, slicer discipline, evaluation
  checklist. Cited as **[Canon]**.

---

## What the report already does right (do not "fix")

Grounding the assessment: much of the standard checklist **passes**. Future
agents should not churn these.

- **Model shape**: star schema, single-direction one-to-many relationships
  everywhere, zero bidirectional relationships; many-to-many handled via
  bridges + `TREATAS`, fact-to-fact via inactive relationships +
  `USERELATIONSHIP`. Auto date/time disabled (`__PBI_TimeIntelligenceEnabled = 0`),
  no hidden local date tables. **[DAX-Patterns]** and **[Canon]** both demand
  exactly this.
- **DAX hygiene**: `DIVIDE` used for every ratio; `VAR`-structured measures;
  `///` descriptions and display folders on most measures; support measures
  hidden; thresholds surfaced as named constant measures.
- **Layout discipline**: consistent 28px margin / 1224px content width / 12px
  gutters; aligned KPI grids on every page; no overlapping visuals; identical
  header + nav kit repeated on all six primary pages (a proper "signature" in
  **[Canon]** terms); page titles present on every page.
- **Detail gradient**: KPIs top, trends middle, tables bottom on every
  analytical page — the 3-30-300 rule **[Canon]** is already the layout spine.
- **Drillthrough architecture**: user-detail and session-detail pages are
  hidden-in-view-mode drill targets with Back buttons — the canonical
  detail-offloading pattern **[MS-Perf]**, and it keeps primary pages lean.
- **Sensible incomplete-period handling**: `Weekly Active Users` drops the
  incomplete current week rather than plotting a misleading partial point.

---

## Prioritized improvements

| # | What | Where | Effort |
|---|---|---|---|
| 1 | Mark `dim_date` as date table + filter-context measures + generic prior-period shift (implements the decided #153 redesign) | `_Measures.tmdl`, `dim_date.tmdl` | L (decided) |
| 2 | Sync the date/tier/user slicers across pages; give pg_exec a date scope | pg_adopt/impact/capacity/eco slicers, `report.json` sync groups | S |
| 3 | Accessibility pass: alt text on non-decorative visuals, decorative chrome out of tab order | all 8 pages (210 visuals, ~66 chrome objects) | M |
| 4 | KPI gap/trend treatment on non-exec KPI rows (falls out of #1) + conditional formatting on the gap | pg_adopt, pg_capacity, pg_eco KPI rows | M |
| 5 | Top-N + explicit sort on high-cardinality bar axes | pg_exec `cht_topusers`, pg_eco 5 bars | S |
| 6 | Fill pg_impact's dead top band with a proper KPI row | pg_impact | S |
| 7 | Model hygiene: stop implicit aggregation on raw fact columns | fact table TMDLs | S |
| 8 | (Optional, after #1) collapse Current/Prior/Δ measure families with a calculation group | semantic model | M |

### 1. Time-intelligence foundation — the concrete pattern for the decided redesign

**What's there:** ~17 measures copy-paste the same
`VAR Anchor = CALCULATE(MAX(dim_date[date_day]), ALL(dim_date))` +
`DATESBETWEEN(dim_date[date_day], Anchor-27, Anchor)` block (Active Users 28d,
New/Retained/Reactivated Users 28d, Off-Roster Active Users 28d, Commits/PRs/
LOC/TAR 28d + Prior 28d triplets, Tokens 28d, Weekly Active Users). The window
length is a literal in every measure; the visuals ignore any date selection.
`dim_date` has `dataCategory: Time` but **no `markAsDateTable` — it is not
actually marked as a date table** in the TMDL.

**Best practice** **[DAX-Patterns]**: the date table must be *marked* as a date
table — marking applies an automatic `REMOVEFILTERS` on the table whenever the
date column is filtered, which is what makes time-intelligence functions behave
when visuals slice by non-date columns (this report slices by `week_label`
everywhere). Dates must be contiguous full years. Both are prerequisites for
`DATEADD` **[SQLBI-DATEADD]**.

**Pattern to implement (per the locked #153 decision):**

1. Add `markAsDateTable` to `dim_date` (TMDL: the `dataCategory: Time` +
   isKey date column is necessary but not sufficient).
2. Base measures become plain filter-context aggregations (they already exist:
   `Total Commits`, `Total PRs`, `Active Users`, …). The **window** comes from a
   report-level relative-date slicer defaulting to "last 28 days" — not from DAX.
3. One generic prior-period shift per base measure, same length as whatever the
   user selected:

   ```dax
   Commits PP :=
   VAR DaysInPeriod = COUNTROWS ( dim_date )          -- days in current selection
   VAR FirstDay = MIN ( dim_date[date_day] )
   RETURN CALCULATE (
       [Total Commits],
       DATESBETWEEN ( dim_date[date_day], FirstDay - DaysInPeriod, FirstDay - 1 )
   )
   ```

   `DATEADD ( dim_date[date_day], -28, DAY )` is equivalent only for a fixed
   28-day contiguous selection; the `DATESBETWEEN` form generalizes to any
   selected window length and sidesteps DATEADD's contiguous-selection
   requirement **[SQLBI-DATEADD]**. (Repo trap already on record: don't reach
   for `DATESINPERIOD` — it clamps out-of-range anchors; map #153 notes this.)
4. Δ measures become `DIVIDE ( [X] - [X PP], [X PP] )` (or pp-difference for
   rates), and the "vs prior 28d" label strings become dynamic:
   `"vs prior " & COUNTROWS ( dim_date ) & " days"`.
5. **Keep the anchor semantics for freshness-lagged data**: the current
   anchoring to `MAX(date_day)` rather than `TODAY()` is deliberate (import
   lag). The relative-date slicer anchors to today; if ingest stalls, "last 28
   days" quietly loses trailing days. Mitigate by keeping the freshness pill
   (already in the header on every page) as the canonical staleness signal —
   this is exactly the `DateWithSales`-boundary concern **[DAX-Patterns]**
   applied to this dataset. Worth an explicit check in the implementation
   ticket's test plan.
6. Growth-accounting measures (New/Retained/Reactivated) keep their
   set-algebra shape but read both windows from filter context: current window
   = `VALUES(dim_date[date_day])`, prior window = the same `DATESBETWEEN` shift.

**Effort:** L, but already decided — this section is the spec input, not a new
recommendation.

### 2. Slicer sync + date scope on pg_exec

**What's there:** pg_adopt, pg_impact, pg_capacity, pg_eco each carry their own
date/tier/user dropdown slicers — same fields, same positions, **no sync
groups** (`report.json` has none). A selection on one page silently resets on
the next; a viewer comparing Adoption and Impact for one tier re-picks the tier.
pg_exec and pg_health have no slicers at all — for pg_exec that was forced by
the anchored measures; after #1 the exec page *must* participate in the
report-level date window anyway.

**Best practice:** consistent slicer collections across pages, same position
**[MS-A11y]** (slicer checklist); sync slicers rather than duplicating
disconnected ones **[Canon]**. Three slicers per page is already at the canon's
maximum, so don't add more — sync the existing three.

**Fix:** add sync groups for the three slicers across the four analytical pages;
after #1, extend the date scope to pg_exec (as the report-level relative-date
filter or a synced-but-hidden slicer, per the #153 decision). pg_health should
*stay* unscoped-by-tier/user (its off-roster/unknown KPIs deliberately look
outside the roster) — scope it by date only if the DQ tables grow.

**Effort:** S (PBIR: one `syncGroup` block per slicer; check `pbir-gotchas`
first).

### 3. Accessibility pass — alt text and tab order

**What's there:** **zero alt text on any of the 210 visuals**, and every
decorative object — logo, header rule, hero rule, nav underline (`ab_nav_line`),
freshness-pill chrome — **carries a tab order**, so keyboard/screen-reader users
tab through ~11 chrome objects per page before reaching data.

**Best practice** **[MS-A11y]**: "add alt text to every object that conveys
meaningful information"; "make sure any decorative shapes are hidden in the tab
order, so screen readers don't announce them". Screen readers announce title +
visual type automatically, so alt text should carry the *takeaway*, not repeat
the title. For KPI cards, use conditional (measure-driven) alt text so the
announced value tracks the data — the dynamic Δ-label measures being built in #1
can double as alt-text expressions for free.

**Fix (mechanical, scriptable over PBIR JSON):**

- Hide from tab order: `img_logo`, `ln_header`, `ln_hero`, `ab_nav_line`,
  `ab_fresh_pill` shell, and the `lbl_*` label textboxes (their text duplicates
  what the adjacent card's alt text will say) on all 8 pages.
- Add `altText` (static or measure-bound) to every chart, table, and KPI card.
  Textboxes that convey content (subtitles, the session-detail hint) get their
  content mirrored into alt text per the textbox checklist item **[MS-A11y]**.
- While in there: verify each visual's sort is purposeful — the accessible
  "Show Data" table exposes whatever sort is set **[MS-A11y]** (see #5).

**Effort:** M — wide but mechanical; one pass with `pbi-cli`/JSON edits +
`validate.ps1`.

### 4. KPI gap/trend treatment beyond the exec page

**What's there:** pg_exec's KPI strip is the canon-correct silhouette — value +
Δ card ("+x% vs prior 28d"). But the KPI rows on pg_adopt (5 cards),
pg_capacity (4), pg_eco (5), pg_health (5) are **bare numbers**: no comparison,
no trend. "Cache Hit Ratio 87%" answers neither "is this good?" nor "is it
getting better?" **[Canon]**: every KPI must carry a target or prior-period gap;
apply conditional formatting to the **gap**, not the primary value; pair color
with a sign/icon (the exec Δ labels already embed `+`/`-` signs — keep that, it
is the accessibility pairing **[MS-A11y]** requires).

**Fix:** after #1, PP/Δ measures exist generically for every base measure, so
the exec KPI silhouette (value card + Δ card) extends to the other KPI rows at
near-zero DAX cost — it's a visual-placement task. Where a Δ is meaningless
(pg_health's `Hours Since Last Signal` already encodes its own
thresholds; `DQ Findings` wants "new since last refresh" rather than a
pp-delta), leave the card bare deliberately rather than inventing a comparison.
Apply the existing status-color approach (freshness pill) as conditional
formatting on Δ text where sentiment is unambiguous.

**Effort:** M — mostly PBIR layout (each Δ card + reflow), DAX falls out of #1.

### 5. Top-N caps and explicit sort on high-cardinality bars

**What's there:** `cht_topusers` (pg_exec) plots `dim_user[user_email]` with
**no Top-N filter** — one bar per user forever; as the fleet grows this becomes
unreadable and progressively slower. The five ecosystem bars (skill/mcp/agent/
hook/plugin names) are similarly uncapped. Sort is not explicitly pinned on
these visuals.

**Best practice** **[MS-Perf]**: apply the most restrictive filters; use Top-N
to cap what a visual renders. **[Canon]**: sort by value descending; a "top
users" visual that isn't top-N is an anti-pattern. **[MS-A11y]**: purposeful
sort order per visual.

**Fix:** visual-level Top-N filter (Top 10 by the bound measure) on
`cht_topusers` and each ecosystem bar; pin descending sort by the measure. Title
gains "TOP 10 …" so the cap is honest. (The stale "BY TOKENS" title is already
decided on #153 — while fixing it, also delete or bind the orphan `Tokens 28d`
measure, which its own comment claims powers this visual but nothing binds.)

**Effort:** S.

### 6. pg_impact top band

**What's there:** pg_impact's KPI band (y64–136) contains a single small
`Rejected Edits` card at x560 — the rest of the band is dead space, breaking the
KPI-row signature every other analytical page follows.

**Best practice** **[Canon]**: the 3-30-300 top band carries the page's summary
numbers; the repeated signature is what makes the report read as one artifact.
Repo rule (#104 rebuild): no visual repeated across pages — so do **not** clone
the exec Δ strip.

**Fix:** give Impact its own filter-context KPI row from measures already in the
model and on-theme for this page: `Total Commits`, `Total PRs`,
`Total Lines of Code`, `Tool Acceptance Rate`, `Rejected Edits` — after #1 these
respond to the page's slicers, which is exactly what distinguishes them from the
exec strip (fixed report-window deltas vs sliceable totals). Five cards matches
the adopt/eco/health grid (5 × ~232px). Cross-page-redundancy tension is real
but resolved by the different question each page answers; flag in the
implementation ticket for a human sanity check.

**Effort:** S–M (layout only).

### 7. Model hygiene — implicit aggregation on raw fact columns

**What's there:** fact numeric columns (`commits`, `prs`, `loc_added`,
`duration_s`, token counts, …) are visible with `summarizeBy: sum` /
`SummarizationSetBy = Automatic`. Every number the report shows goes through a
curated measure, but ad-hoc users (and future agents binding fields) can drop a
raw double-typed column on a visual and get a plausible-looking wrong number —
e.g. summing `fact_usage_window` columns is a known repo trap (pct columns are
`summarizeBy: none` already, good; the rest of the facts aren't hardened).

**Best practice:** hide fact-table columns that exist only to feed measures
(standard BPA rule; **[Canon]** rule 7's "fields bound must be deliberate" is
the report-side echo). Where a column stays visible for slicing/tables
(`fact_session.start_type`, `session_id`, timestamps), set `summarizeBy: none`
on numerics that must not be implicitly summed.

**Fix:** one TMDL pass over the six fact tables: `isHidden` on measure-feed
numerics; `summarizeBy: none` on anything that stays visible. Zero visual
impact (visuals bind measures).

**Effort:** S.

### 8. Optional, after #1 — calculation group for Current/Prior/Δ

**What's there:** the measure count (~70) is dominated by structurally identical
families: four Current/Prior/Δ/Label quadruplets (Commits, PRs, LOC, TAR), plus
five `Sessions Using X %` and five `Users Using X` clones. After #1 every base
measure grows a PP and Δ sibling, roughly doubling the explicit-measure surface.

**Best practice** **[DAX-Patterns]**: time-intelligence variants (Current / PP /
Δ%) are the canonical calculation-group use case — one calc group with three
items replaces N×3 measures, with `SELECTEDMEASURE()` and per-item format
strings. The model's compatibilityLevel (1600) supports calculation groups.

**Trade-off (why this is optional, not top-5):** calc-group items apply to
*whatever* measure is in context — including ones where PP is meaningless
(`Paid Seats`, threshold constants, text measures) — so it needs a
measure-allowlist convention; and the report's KPI cards bind *specific*
measures, so cards still need explicit measure references (calc groups shine in
matrices/charts, less on card walls). Recommend deciding this **after** #1
lands, sized against how many explicit PP/Δ measures #1 actually produced.

**Effort:** M (model-only, but changes the measure-authoring convention).

---

## Noted, deliberately not recommended

- **Custom tooltip pages**: none exist; default enhanced tooltips are on.
  Tooltips must not carry key information (keyboard users can't reach them)
  **[MS-A11y]**, and #153 rules out speculative restyling — the current state is
  acceptable. Revisit only if a specific "hover for breakdown" need lands.
- **`kpi` visual type instead of card+Δ-card pairs**: **[Canon]** prefers the
  `kpi` visual when a target exists, but the card+label silhouette is this
  report's established signature; swapping visual types is restyling for its own
  sake.
- **`NOW()` in `Hours Since Last Signal`**: non-deterministic and conflates
  pipeline silence with refresh lag — already acknowledged in the measure's own
  comment and mitigated by `Last Mart Refresh` on pg_health. Semantics change =
  human decision, not a best-practice delta.
- **Bookmarks / mobile layouts**: absent, and nothing in the report's
  desktop-report usage pattern demands them; adding either would be speculative.
- **Seat-roster CSV local path + hardcoded service-account exclusion in RLS
  cleaning**: real maintainability smells, but data-plumbing concerns outside
  this ticket's report-design scope; both are visible to map #153's roster/HR
  decisions (seat-roster regeneration and HR-dedupe are already locked there).
