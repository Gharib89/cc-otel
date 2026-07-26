# powerbi/

Power BI adoption report — `.pbip` project (source of truth), branding assets, and the
Desktop-published semantic model + report.

## Layout

| Path | What |
|---|---|
| `cc-otel-report.pbip` | PBIP project pointer |
| `cc-otel-report.SemanticModel/` | TMDL semantic model (this issue, #27) |
| `cc-otel-report.Report/` | Report pages + theme (#28) |
| `branding/` | AIWorx logo, PPT template, corporate-brand tokens — chart colours feed #28; typography deliberately does not (see `branding/design-tokens.json`) |

## Semantic model (#27)

Import mode. Two sources:

- **Marts** — Azure Postgres `cc_otel` DB, `marts` schema only. The 14 matviews
  (`dim_*`, `fact_*`, `bridge_*`) load via `Value.NativeQuery` (`SELECT … FROM marts.<x>`)
  because Power BI's PostgreSQL connector **does not list materialized views** in the
  Navigator — a plain navigation import can't see them. The two ops **tables**
  (`mart_refresh_log`, `dq_finding`) use ordinary navigation.
- **Employee dim** — Azure SQL `vw_UserBasicInfo` (`itxdatainteg-prod` / `EmployeeSchema`),
  imported directly for org attributes + RLS.

Structure:

- **Star, single direction.** Facts → `dim_user` (`user_email`), `dim_date`
  (`activity_date` → `date_day`), `dim_model` (`fact_api_usage.model`); bridges →
  `fact_session` (session anchor). `fact_session` is the session-grain anchor; the three
  session-carrying facts link to it **inactive** (they reach `dim_user`/`dim_date` directly,
  so an active anchor path would be ambiguous — activate via `USERELATIONSHIP` for drill).
- **Derived `activity_date`.** `fact_session`, `fact_usage_window`, `fact_utilization_hourly`
  hold only a `timestamptz`; the native query casts it to a `date` column so it joins `dim_date`.
- **`dim_date`** marked as the date table (`dataCategory: Time`); model-wide Auto Date/Time off.
- **`_Measures`** — thresholds + adoption/utilization/ingest-health measures; thresholds live
  in DAX (`Limit-Hit Threshold Pct`, `Freshness Amber/Red Hours`), so changing one is a measure
  edit, not a migration.
- **RLS — `OrgScope`** (dynamic): a viewer sees their own employee row plus every row whose
  management chain contains them. `vw_UserBasicInfo` carries a hidden `ManagementPath` calculated
  column (`PATH(Email, ManagerEmailClean)`); the role filters it with
  `Email = USERPRINCIPALNAME() || PATHCONTAINS(ManagementPath, USERPRINCIPALNAME())`.
  The three seat marts (`dim_seat_current`, `dim_seat`, `fact_seat_day`) carry the **same subtree
  predicate restated against the HR view** (#301, ADR-0010), so both the licensed-seat count and the
  184 real roster addresses are viewer-scoped. Each is written out rather than inherited — a security
  filter must not depend on another having already applied. Accepted consequence: seat history is
  viewer-relative, since a departed person has no HR row and their seat-days vanish for role viewers.
  Workspace Admin/Member bypass RLS. Requires a clean, acyclic, same-cased `ManagerEmail` chain.
  The HR view currently violates that (service accounts create cycles), so `ManagerEmailClean`
  carries a **stopgap** exclusion list (`{"internal.application@itworx.com"}`) that roots those
  accounts to break the loop — extend the list if a new cycle surfaces; the durable fix is upstream
  in `vw_UserBasicInfo`.

## Report (#28)

Seven pages, authored offline as PBIR JSON via `pbi-cli-tool` v3.11.1's Report layer
(`pbi report`/`visual`/`format` with `--no-sync`; see `docs/research/pbi-cli-visual-authoring.md`
— a dated snapshot, so its `set-theme` row no longer reflects the theme path below).
Canvas 1280×720. The report's custom theme is
`cc-otel-report.Report/StaticResources/RegisteredResources/AIWorx.json`, hand-edited in place
(routing + the `set-theme` trap: `CLAUDE.md`). It consumes most of `branding/design-tokens.json`
verbatim, but deliberately departs on two: Segoe UI rather than the brand's Century Gothic, and
`logo.wordmark` navy rather than `theme.accent1` (specified in #130, agreed #129, shipped #132).

| Page | Content |
|---|---|
| Overview | 6 fleet KPI cards, daily-active-users trend, requests-by-model-family donut, last-mart-refresh + freshness cards |
| Users | One row per developer — the full [report data contract](../docs/report-data-contract.md) |
| Session drill | Per-session table + all 5 bridge tables (skills/MCP/plugins/subagents/hooks); **hidden**, drillthrough target |
| Usage & capacity | Utilization-intensity + limit-hit KPIs, intensity trend, hour-of-day heatmap matrix |
| Tool quality | Acceptance-rate KPI, edit-decisions-by-language bar, decision-mix donut |
| Ecosystem adoption | Five bars — skills, MCP servers, plugins, subagents, hooks |
| Ingest health | Freshness + unknown-email KPIs, `dq_finding` and `mart_refresh_log` tables |

### Finish in Desktop before publishing (pbi-cli gaps — see research §2/§4)

Drillthrough (Users → Session drill) and the freshness-card colours both landed on disk since
this list was written — drillthrough is configured in `pg_session_detail/page.json`, and the
cards colour themselves from the `Freshness Color` measure on all six pages. What remains:

1. **Fixed per-model-family colours** — pin each `dim_model[family]` series in
   `pg_capacity/cht_tokens_model` to a stable colour so families read consistently report-wide.
2. **Publish** — manual from Desktop to the **Pro** workspace `cc-otel` (ADR-0014: PPU would
   block every Pro-licensed manager and buys nothing this report uses). Public Postgres, no
   gateway. Scheduled refresh runs **twice** daily, 07:30 and 19:30 Cairo: `Hours Since Last
   Signal` measures against query-time `NOW()` while the imported `last_event_ts` freezes at
   refresh, so a single daily slot drives the freshness cards to Amber (24h threshold) every
   evening on a healthy pipeline. The `:30` offset clears the hourly `marts.refresh_all()`.

### Audiences — Data Health is owner + IS only

The report is distributed as a **Power BI App with audiences** (ADR-0014 — consumers get no
workspace role at all, so `OrgScope` always applies). The **Data Health** page
(`pg_health`) goes to the owner/IS audience only — never a manager audience. The reason is product,
not security: `OrgScope` (ADR-0010) makes the page *safe* for a manager, but not *truthful*. Its
off-roster-active-users and identity-mismatch visuals key on identities with no HR row, so under the
role they render zero and empty — the page reads "everything is fine" precisely when it is not.
Scoping is the model's job and holds regardless of audience (see RLS above); the audience split here
only keeps a page whose meaning depends on org-wide visibility away from viewers who lack it.

## CI validation

`.github/workflows/ci-powerbi.yml` gates every `powerbi/**` change (path-filtered
per concern, CLAUDE.md). Three checks: PBIR/PBIP JSON-schema validation (ajv),
`fab-inspector` report-quality rules (ubuntu), and Tabular Editor 2 Best Practice
Analyzer against the semantic model (windows). Nothing is deployed — publishing
stays manual from Desktop. Pinned tool versions + vendored rulesets live in
`.github/powerbi/` (see its README).

## Connect / refresh (Desktop)

Data-source credentials (per `bootstrap.ps1 powerbi` step):

- **Postgres** — connect as `cc_otel_read_user` (password `.env` `CC_OTEL_READ_PASSWORD`),
  SSL required. It has SELECT on the whole `marts` schema.
- **Azure SQL** — the employee-dataset login (`.env` `AZURE_DB_USER` / `AZURE_DB_PASSWORD`).

Open `cc-otel-report.pbip`, Refresh, then spot-check RLS with **View as → OrgScope**.
`.pbip` is the source of truth; publishing is manual from Desktop.

## Environments

The model hardcodes the **interim** Postgres FQDN (`ccotel-pg-interim.…`). The prod swap is a
find/replace of the server literal (or Desktop data-source edit) at cutover (#83).
