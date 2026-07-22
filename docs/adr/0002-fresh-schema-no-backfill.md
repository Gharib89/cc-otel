# Production Postgres starts with a fresh schema-v2; POC pilot data is not backfilled

The production Azure Postgres database starts empty on a redesigned schema — schema-v2: no `spans` (ADR-0001), no cost columns in marts, promoted `window`/`edit_type` columns, materialized daily marts, `meta.column_registry`. We considered a one-time backfill of the ~6 weeks of POC pilot data (`pg_dump` → staging → mapped insert) and rejected it: the pilot covered 2–6 devs, the new report targets a 150–200-dev rollout where pilot history is statistically irrelevant, and skipping the mapping removes a whole class of old-schema/new-schema translation bugs. Consequence: when the POC stack is decommissioned after cutover (see parallel cutover in CONTEXT.md), pilot history is permanently gone.

**Superseded for the interim environment by ADR-0006** — interim is backfilled with mapped POC history; production still starts fresh per this ADR.

**The "no cost columns in marts" clause is superseded by ADR-0007** — `cost_usd` is promoted into `marts.fact_api_usage` as API-equivalent value consumed (per decision #158). The rest of schema-v2 stands.
