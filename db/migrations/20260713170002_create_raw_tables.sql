-- migrate:up

-- Sink-owned base tables. Promoted typed columns only — no `attrs`/`resource` JSONB
-- (ADR-0005: unpromoted keys survive in the blob reservoir, not Postgres). Column set =
-- the POC parser's promoted list minus trace-only fields, plus the schema-v2 additions
-- the locked star schema (#9) consumes but the POC left in JSONB. Every column has a
-- matching meta.column_registry row (seeded in a later migration). Append-only:
-- idempotency is enforced by meta.processed_batches, not a table PK.

CREATE TABLE raw.metrics (
    ts TIMESTAMPTZ NOT NULL,   -- OTel data-point time (timeUnixNano)
    metric_name TEXT NOT NULL,          -- instrument name, e.g. claude_code.token.usage
    metric_type TEXT NOT NULL,          -- gauge / sum / histogram
    value DOUBLE PRECISION,       -- canonical numeric data-point value
    count BIGINT,                 -- pre-aggregated count on histogram instruments
    value_kind TEXT,                   -- gauge_last / sum_delta / sum_cumulative / hist_sum
    user_email TEXT,                   -- normalized (lowercased/trimmed) developer identity
    -- Anthropic account id (user.account_uuid / user.account_id)
    user_account_id TEXT,
    organization_id TEXT,
    session_id UUID,
    model TEXT,
    -- polymorphic `type` attr: input/output/cacheRead/cacheCreation (token.usage),
    -- user/cli (active_time.total), or added/removed (lines_of_code.count)
    type_label TEXT,
    tool_name TEXT,                   -- code_edit_tool.decision
    decision TEXT,                   -- accept / reject
    -- decision source on code_edit_tool.decision (schema-v2 add for fact_edit_decision)
    source TEXT,
    language TEXT,
    -- rate-limit window (5h/7d/...); `window` attr (schema-v2 add for fact_usage_window)
    usage_window TEXT,
    cc_version TEXT,                   -- app.version, coalesced over resource service.version
    query_source TEXT,
    effort TEXT,
    speed TEXT,
    agent_name TEXT,
    skill_name TEXT,
    plugin_name TEXT,
    marketplace_name TEXT,
    start_type TEXT,                   -- session.count
    scope_name TEXT,
    scope_version TEXT
);

CREATE INDEX metrics_ts_idx ON raw.metrics (ts DESC);
CREATE INDEX metrics_name_ts_idx ON raw.metrics (metric_name, ts DESC);
CREATE INDEX metrics_user_ts_idx ON raw.metrics (user_email, ts DESC);

CREATE TABLE raw.events (
    event_time TIMESTAMPTZ NOT NULL,   -- log-record time (timeUnixNano)
    event_name TEXT NOT NULL,          -- event.name, e.g. api_request, tool_decision
    severity TEXT,                   -- severityText
    -- OTLP log-record body (event-name string for CC events; the `body` attr on
    -- api_*_body events is a different, denied key)
    body TEXT,
    user_email TEXT,                   -- normalized developer identity
    user_account_id TEXT,
    organization_id TEXT,
    session_id UUID,
    prompt_id UUID,
    model TEXT,
    tool_name TEXT,                   -- tool_decision / tool_result (incl. mcp__* names)
    duration_ms BIGINT,
    input_tokens BIGINT,
    output_tokens BIGINT,
    cache_creation_tokens BIGINT,
    cache_read_tokens BIGINT,
    cost_usd DOUBLE PRECISION,       -- archived; marts are adoption-only (no cost)
    cc_version TEXT,
    event_sequence BIGINT,
    request_id TEXT,
    speed TEXT,
    effort TEXT,
    query_source TEXT,
    prompt_length BIGINT,
    command_name TEXT,
    command_source TEXT,
    hook_name TEXT,
    hook_event TEXT,
    from_mode TEXT,
    to_mode TEXT,
    trigger TEXT,
    skill_name TEXT,
    -- api_request attribution (schema-v2 add for bridge_session_agent)
    agent_name TEXT,
    plugin_name TEXT,                   -- plugin_loaded (schema-v2 add for bridge_session_plugin)
    marketplace_name TEXT,                   -- attribution (schema-v2 add)
    -- api_request attribution (schema-v2 add for bridge_session_mcp)
    mcp_server_name TEXT,
    mcp_tool_name TEXT,                   -- api_request attribution (schema-v2 add)
    mention_type TEXT,
    success_bool BOOLEAN,
    tool_use_id TEXT,
    decision TEXT,                   -- tool_decision accept/reject
    source TEXT,                   -- tool_decision source
    scope_name TEXT,
    scope_version TEXT,
    severity_number SMALLINT,
    log_trace_id TEXT,
    log_span_id TEXT,
    dropped_attributes_count INTEGER
);

CREATE INDEX events_time_idx ON raw.events (event_time DESC);
CREATE INDEX events_name_time_idx ON raw.events (event_name, event_time DESC);
CREATE INDEX events_session_idx ON raw.events (session_id);

GRANT INSERT ON raw.metrics, raw.events TO cc_otel_ingest;
GRANT SELECT ON raw.metrics, raw.events TO cc_otel_read;

-- migrate:down

DROP TABLE IF EXISTS raw.events;
DROP TABLE IF EXISTS raw.metrics;
