-- Canonical definition for staging.stg_counter_delta.
-- Source of truth for the view body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name stg_counter_delta
-- Verified against pg_views.definition by --check (CI + local gate).
CREATE OR REPLACE VIEW staging.stg_counter_delta AS
 SELECT ts,
    metric_name,
    value,
    user_email,
    session_id,
    model,
    type_label,
    tool_name,
    decision,
    source,
    language,
    usage_window,
    cc_version,
    query_source,
    effort,
    speed,
    agent_name,
    skill_name,
    start_type
   FROM raw.metrics
  WHERE ((metric_type = 'sum'::text) AND (value_kind = 'sum_delta'::text));
