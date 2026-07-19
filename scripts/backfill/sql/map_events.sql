-- POC otel.events (schema-v1) -> interim raw.events (schema-v2) column mapping (#131).
-- Runs on the POC side inside COPY (<this SELECT>) TO STDOUT, and is reused verbatim by
-- the integration test as INSERT INTO backfill_stg.events <this SELECT>. Column order MUST
-- match raw.events exactly. Same-named columns copy 1:1; agent/plugin/marketplace/mcp
-- names and decision are lifted out of attrs, mirroring what the v2 sink parser writes
-- (POC left them in JSONB and never promoted them). attrs/resource JSONB are dropped.
-- Scope filter + session dedup are applied later in load.sql.
-- Window: 2026-05-24 .. 2026-07-16 inclusive (POC last day).
SELECT
    event_time,
    event_name,
    severity,
    body,
    user_email,
    user_account_id,
    organization_id,
    session_id,
    prompt_id,
    model,
    tool_name,
    duration_ms,
    input_tokens,
    output_tokens,
    cache_creation_tokens,
    cache_read_tokens,
    cost_usd,
    cc_version,
    event_sequence,
    request_id,
    speed,
    effort,
    query_source,
    prompt_length,
    command_name,
    command_source,
    hook_name,
    hook_event,
    from_mode,
    to_mode,
    trigger,
    skill_name,
    attrs ->> 'agent.name' AS agent_name,
    attrs ->> 'plugin.name' AS plugin_name,
    attrs ->> 'marketplace.name' AS marketplace_name,
    attrs ->> 'mcp_server.name' AS mcp_server_name,
    attrs ->> 'mcp_tool.name' AS mcp_tool_name,
    mention_type,
    success_bool,
    tool_use_id,
    attrs ->> 'decision' AS decision,
    source,
    scope_name,
    scope_version,
    severity_number,
    log_trace_id,
    log_span_id,
    dropped_attributes_count
FROM events
WHERE event_time >= DATE '2026-05-24' AND event_time < DATE '2026-07-17'
