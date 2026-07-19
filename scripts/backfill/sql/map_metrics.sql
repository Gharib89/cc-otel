-- POC otel.metrics (schema-v1) -> interim raw.metrics (schema-v2) column mapping (#131).
-- Runs on the POC side inside COPY (<this SELECT>) TO STDOUT, and is reused verbatim by
-- the integration test as INSERT INTO backfill_stg.metrics <this SELECT>. Column order
-- MUST match raw.metrics exactly. Same-named columns copy 1:1; token_type is renamed and
-- usage_window/source are lifted out of attrs, mirroring what the v2 sink parser writes.
-- attrs/resource JSONB are dropped (schema-v2 has no JSONB). Scope filter + session dedup
-- are applied later in load.sql, where interim's own session set is visible.
-- Window: 2026-05-24 (first clean all-sum_delta day) .. 2026-07-16 inclusive (POC last day).
SELECT
    ts,
    metric_name,
    metric_type,
    value,
    count,
    value_kind,
    user_email,
    user_account_id,
    organization_id,
    session_id,
    model,
    token_type AS type_label,
    tool_name,
    decision,
    attrs ->> 'source' AS source,
    language,
    attrs ->> 'window' AS usage_window,
    cc_version,
    query_source,
    effort,
    speed,
    agent_name,
    skill_name,
    plugin_name,
    marketplace_name,
    start_type,
    scope_name,
    scope_version
FROM metrics
WHERE ts >= DATE '2026-05-24' AND ts < DATE '2026-07-17'
