# powerbi/

Power BI adoption report — `.pbip` project, branding assets, and the Desktop-published semantic
model + report.

> **Frozen since 2026-08-03.** The report is owned and authored in the Power BI Service by Mohamed
> Atallah; this tree is an archive of the last repo-authored state and is no longer the source of
> truth (ADR-0022). Operating manual for the owner: [`HANDOVER.md`](HANDOVER.md). Everything below
> describes the model and report as archived.

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
  Navigator — a plain navigation import can't see them. The two ops objects use ordinary
  navigation: the `mart_refresh_log` **table**, and the `dq_finding_current` **view** (plain
  views the Navigator does list), which enters the model under the name `dq_finding`. The
  underlying `marts.dq_finding` is an append-only detection log — importing it counted
  detections as findings (ADR-0019).
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
2. **Publish** — manual from Desktop to the **PPU** workspace **AIWorx**. Public Postgres, no
   gateway; the Power BI service also reaches the HR view on `itxdatainteg-prod` Azure SQL
   directly (first refresh, 2026-07-26), so neither source needs a gateway or an IS firewall
   change. Scheduled refresh runs **hourly at `:30`** (24 of PPU's 48 daily slots). Both
   halves of that matter (ADR-0014): the `:30` offset clears the hourly `marts.refresh_all()`,
   and hourly rather than daily is what makes the freshness cards honest — `Hours Since Last
   Signal` measures query-time `NOW()` against an imported `last_event_ts` frozen at refresh,
   so a sparse schedule reports the report's own refresh lag instead of pipeline silence.
   Every consumer needs a PPU seat; the tenant has no Pro SKU, so that is the only paid seat
   available and a Pro workspace would reach nobody extra.
3. **Name it for consumers** — the app is **Claude Code Adoption**. That name, not the item
   names, is what consumers meet: they reach the report through the app and hold no workspace
   role. Both `.platform` files carry the same `displayName`, but the first publish (2026-07-26)
   landed the items as **`cc-otel-report`** anyway — Desktop appears to name published items
   from the `.pbip`/folder name, so treat `.platform` `displayName` as Fabric-git metadata that
   Desktop publishing ignores. The `.pbip` and folder names stay `cc-otel-report` regardless:
   every CI path, lint default, skill and doc references them, and no consumer sees them.
   Never rename the published items **in the Service**: republish matches by name, so the next
   publish would create a duplicate pair and leave the app bound to the old report while fresh
   data landed in the new one.

### Distribution — one audience, and Data Health is visible to it

The report is distributed as a **Power BI App** (ADR-0014 — consumers get no workspace role at
all, so `OrgScope` always applies). It has a **single audience**: managers.

An earlier version of this section reserved the **Data Health** page (`pg_health`) for an
owner/IS audience. That design is dropped because it can't be built. App audiences scope
**items** — reports, dashboards, links — not pages within a report, and hiding a page doesn't
help either: every visible page carries a `nav_health` button, and page-navigation buttons reach
hidden pages perfectly well. Delivering it would have meant splitting the report in two over the
same semantic model, which was judged not worth a second PBIR artifact and permanent page-set
drift.

**Accepted consequence, deliberately not tracked:** a manager can open Data Health, and under
`OrgScope` (ADR-0010) it is *safe* but not *truthful*. Its off-roster-active-users and
identity-mismatch visuals key on identities with no HR row, so under the role they render zero
and empty — the page reads "everything is fine" precisely when it is not. Scoping is the model's
job and holds regardless (see RLS above); what's lost is only the guarantee that nobody reads a
page whose meaning depends on org-wide visibility. If that misreading ever costs something, the
cheap fix is a viewer-scoped banner on the page, not an audience split.

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

Open `cc-otel-report.pbip`, Refresh, then spot-check RLS with **View as → OrgScope**. Reaching
`ccotel-pg-prod` from Desktop needs the ITWorx VPN (no open-internet firewall rule — ADR-0018); the
Service needs no such thing.

## Environments

The Postgres server and database are **M parameters**, not literals:
`cc-otel-report.SemanticModel/definition/expressions.tmdl` declares `PgHost` and `PgDatabase`
(`Type="Text"`) and all 21 partitions read
`PostgreSQL.Database(#"PgHost", #"PgDatabase")`. Current values are production —
`ccotel-pg-prod.postgres.database.azure.com` / `cc_otel` (#247, ADR-0022).

Moving environments is therefore a value edit in the Service (Semantic model settings → Data access →
**M parameters**), not a file change: parameterized sources still refresh, and parameter values are
editable there. **Credentials are bound per server**, so re-enter the Postgres credentials after any
`PgHost` change or the next refresh fails. The Azure SQL HR source stays a literal — one server,
IS-owned, doesn't move.
