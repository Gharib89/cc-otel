# powerbi/

Power BI adoption report — `.pbip` project (source of truth), branding assets, and the
Desktop-published semantic model + report.

## Layout

| Path | What |
|---|---|
| `cc-otel-report.pbip` | PBIP project pointer |
| `cc-otel-report.SemanticModel/` | TMDL semantic model (this issue, #27) |
| `cc-otel-report.Report/` | Report pages + theme (#28) |
| `branding/` | AIWorx logo, PPT template, design tokens (theme source for #28) |

## Semantic model (#27)

Import mode. Two sources:

- **Marts** — Azure Postgres `cc_otel` DB, `marts` schema only. The 13 matviews
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
  management chain contains them, via `PATHCONTAINS(PATH(Email, ManagerEmail), USERPRINCIPALNAME())`.
  Workspace Admin/Member bypass RLS. Requires a clean, acyclic, same-cased `ManagerEmail` chain.

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
