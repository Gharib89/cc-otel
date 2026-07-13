-- migrate:up

-- Staging layer (#19): plain views over raw that resolve temporality and typing
-- ONCE, so the marts never see value_kind. Delta-only by design (#9): the fleet
-- pins OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta, so every counter
-- datapoint already IS its own delta — no LAG/cumulative math. Any sum_cumulative
-- row is excluded here and recorded as a dq_finding at refresh time (see the refresh
-- migration), never silently modeled.
--
-- Event-name convention: metric_name carries the `claude_code.` prefix
-- (e.g. claude_code.commit.count); event_name is stored bare (e.g. api_request).
-- Both follow the meta.column_registry seed, which is the sink's write contract.
CREATE SCHEMA IF NOT EXISTS staging;

-- Delta-only counter datapoints. value = the per-datapoint delta directly.
CREATE VIEW staging.stg_counter_delta AS
SELECT
    ts,
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
WHERE metric_type = 'sum'
  AND value_kind = 'sum_delta';

-- Typed projection of api_request log events — the densest usage signal, richer
-- than the token.usage metric (carries model/effort/query_source per request).
CREATE VIEW staging.stg_api_request AS
SELECT
    event_time,
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
    cc_version
FROM raw.events
WHERE event_name = 'api_request';

GRANT USAGE ON SCHEMA staging TO cc_otel_read;
GRANT SELECT ON ALL TABLES IN SCHEMA staging TO cc_otel_read;

-- migrate:down

DROP VIEW IF EXISTS staging.stg_api_request;
DROP VIEW IF EXISTS staging.stg_counter_delta;
DROP SCHEMA IF EXISTS staging;
