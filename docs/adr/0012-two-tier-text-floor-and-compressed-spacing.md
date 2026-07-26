# The report carries a two-tier text floor and an 8-unit inter-group gap, both below the design canon

**Status:** accepted

The design canon (`reports:pbi-report-design`) states a 12pt readable minimum for text
and 24-32 units for an inter-group boundary. #309 raised the KPI band to 12pt; the design
review on its PR then surfaced that the rest of the report sits below both floors, filed
as #315-#318. Applying the canon literally is not available: raising bar-chart category
labels to 12pt truncates strings that already truncate at 9pt, raising table rows to 12pt
costs two visible rows on every leaderboard, and 24 units of inter-group gap does not
exist on `pg_health` (16 units of page slack) or `pg_eco` (6). Decision log: #315-#318.

This ADR does not weaken the canon generally — it governs everything else, including the
12pt floor for the text a reader actually reads as prose. It records two scoped
divergences and the test that decides which side of the first one an element falls on.

## Decisions

- **Two-tier text floor: 12pt chrome, 10pt dense.** Text that frames the data meets the
  canon's 12pt. Text that *is* the data has a 10pt hard floor instead. Nothing in the
  report is authored below 10pt.
- **Tier membership is decided by string provenance, not by widget type.** The test is
  one question: *can this string be shortened by editing the report?* If yes it is
  **chrome** and meets 12pt -- visual titles, page subtitles, hints, notes, tooltip text,
  legend series names, and table column-header captions, which are our own column names.
  If shortening it would mean changing the data, it is **dense** and 10pt is the floor --
  category and axis tick labels, data labels, grid cell values, and matrix headers bound
  to a data column. Widget type is the wrong discriminator: a `tableEx` column header is
  chrome while a `pivotTable` column header bound to `hour_of_day` is dense, and both are
  "a column header".
- **The rule is the trade it encodes.** Chrome collides with width and the fix is to
  rewrite the string, which #309 already did five times (`TOOL ACCEPTANCE RATE` ->
  `TOOL ACCEPT`). Dense collides with width and no such move exists, so the choice is
  between size and information. We take information: visible rows and untruncated
  category names beat two points of type.
- **Inter-group spacing is 8 units, not 24-32.** The canon's tier presumes no title-bar
  chrome; every chart here wears a solid saturated navy title bar, so figure-ground
  carries the group boundary that whitespace carries in the canon's model. The report runs
  a compressed spacing budget throughout and 8 is consistent with that signature.
- **What was actually broken was the ratio, not the absolute.** Intra-card tier spacing is
  0-2 units and the gap to the chart row was also 2 -- on `pg_eco` the label row and value
  card overlapped by 2 -- so spacing carried no grouping signal at all. 8 against an
  intra-card 0-2 is a 4x ratio, which is the signal the canon's number is a proxy for.
- **Both floors are enforced by `gotchas-lint.mjs`, not by prose.** Per CLAUDE.md the
  config is the spec; this ADR carries only the reasoning and the provenance test, which a
  linter cannot express. It also discharges #309's decision-5 deferral (a card
  `labels.fontSize >= 12` rule, promised as "tracked separately" and never filed) -- that
  rule is a strict subset of this one.

## Consequences

- An element that cannot meet its own tier's floor is a defect in the *element*, not a
  reason to lower the floor. `pg_capacity/cht_util_heatmap` pins `columnWidth: 14` to fit
  24 hour columns in 410 units; a two-digit label needs ~20 at 8pt and ~22 at 10pt, so it
  fails the dense floor at any legible size. The rule converted a vague "8pt is too small"
  into "24 data-derived columns do not fit here", and the visual is being replaced rather
  than exempted.
- `pg_eco` is the page with no slack in either dimension. It pays its gap from chart
  height (238 -> 230), the same move #309 made there (210 -> 202). It pays 8, not the 6
  the other pages pay: closing its 2-unit label/value overlap in the same pass (#316)
  pushes its band 2 units lower, and the gap is measured from the band's new bottom.
- A design review that re-files "text is below 12pt" against dense elements is answered by
  this ADR, not re-litigated. New elements get the provenance test.
- `CONTEXT.md` carries *chrome tier* and *dense tier* as glossary terms so the split is
  named the same way in issues, lint messages, and review comments.
