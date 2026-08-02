# Production Postgres starts with a fresh schema-v2; POC pilot data is not backfilled

The production Azure Postgres database starts empty on a redesigned schema — schema-v2: no `spans` (ADR-0001), no cost columns in marts, promoted `window`/`edit_type` columns, materialized daily marts, `meta.column_registry`. We considered a one-time backfill of the ~6 weeks of POC pilot data (`pg_dump` → staging → mapped insert) and rejected it: the pilot covered 2–6 devs, the new report targets a 150–200-dev rollout where pilot history is statistically irrelevant, and skipping the mapping removes a whole class of old-schema/new-schema translation bugs. Consequence: when the POC stack is decommissioned after cutover (see parallel cutover in CONTEXT.md), pilot history is permanently gone.

**Superseded for the interim environment by ADR-0006** — interim is backfilled with mapped POC history; production is not.

**Amended by ADR-0017 for the interim curation window** — interim's own redacted reservoir blobs are re-driven through the current sink so newly promoted columns carry history from 2026-07-17, which is neither a POC backfill nor an old-schema translation. That replay left production untouched.

**Amended by ADR-0020 for the cutover window** — production inherits interim's own live telemetry from `2026-07-17 00:00:00+00` onward, an identity schema-v2 copy of the same fleet's rows. No old-schema history is translated, which is the thing this ADR rejects; ADR-0006's mapped pilot history stays behind in interim.

**The "no cost columns in marts" clause is superseded by ADR-0007** — `cost_usd` is promoted into `marts.fact_api_usage` as API-equivalent value consumed (per decision #158). The rest of schema-v2 stands.
