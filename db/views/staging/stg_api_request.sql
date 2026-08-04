-- Canonical definition for staging.stg_api_request.
-- Source of truth for the view body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name stg_api_request
-- Verified against pg_views.definition by --check (CI + local gate).
CREATE OR REPLACE VIEW staging.stg_api_request AS
 SELECT event_time,
    session_id,
    user_email,
    model,
    input_tokens,
    output_tokens,
    cache_creation_tokens,
    cache_read_tokens,
    query_source,
    effort,
    speed,
    agent_name,
    skill_name,
    mcp_server_name,
    mcp_tool_name,
    cc_version,
    cost_usd
   FROM raw.events
  WHERE (event_name = 'api_request'::text);
