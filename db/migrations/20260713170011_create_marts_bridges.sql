-- migrate:up

-- Bridges (#9): session × name + count, for the multivalued session-drill fields. The
-- NAME column IS the dimension — no name-list dim tables. Names are kept verbatim
-- (OTEL_LOG_TOOL_DETAILS=1 is pinned fleet-wide, #8).

-- bridge_session_skill: skill activations — skill_activated events ∪ api_request skill
-- attribution.
CREATE MATERIALIZED VIEW marts.bridge_session_skill AS
SELECT session_id, skill_name, COUNT(*) AS activations
FROM raw.events
WHERE event_name IN ('skill_activated', 'api_request')
    AND session_id IS NOT NULL AND skill_name IS NOT NULL
GROUP BY session_id, skill_name;

CREATE UNIQUE INDEX bridge_session_skill_pk
    ON marts.bridge_session_skill (session_id, skill_name);

-- bridge_session_mcp: MCP tool calls — mcp__* tool names on tool_result ∪ mcp_server.name
-- on api_request. Names kept verbatim as emitted.
CREATE MATERIALIZED VIEW marts.bridge_session_mcp AS
WITH names AS (
    SELECT session_id, tool_name AS mcp_name
    FROM raw.events
    WHERE event_name = 'tool_result' AND session_id IS NOT NULL AND tool_name LIKE 'mcp__%'
    UNION ALL
    SELECT session_id, mcp_server_name
    FROM raw.events
    WHERE event_name = 'api_request' AND session_id IS NOT NULL AND mcp_server_name IS NOT NULL
)
SELECT session_id, mcp_name, COUNT(*) AS tool_calls
FROM names
GROUP BY session_id, mcp_name;

CREATE UNIQUE INDEX bridge_session_mcp_pk
    ON marts.bridge_session_mcp (session_id, mcp_name);

-- bridge_session_plugin: plugins loaded at session start (loaded = active).
CREATE MATERIALIZED VIEW marts.bridge_session_plugin AS
SELECT session_id, plugin_name, COUNT(*) AS load_count
FROM raw.events
WHERE event_name = 'plugin_loaded' AND session_id IS NOT NULL AND plugin_name IS NOT NULL
GROUP BY session_id, plugin_name;

CREATE UNIQUE INDEX bridge_session_plugin_pk
    ON marts.bridge_session_plugin (session_id, plugin_name);

-- bridge_session_agent: subagent invocations — from api_request agent attribution. (The
-- Task/Agent subagent_type fallback named in #9 has no promoted raw column to source
-- from, so it is not implemented here — see the PR notes.)
CREATE MATERIALIZED VIEW marts.bridge_session_agent AS
SELECT session_id, agent_name, COUNT(*) AS invocations
FROM raw.events
WHERE event_name = 'api_request' AND session_id IS NOT NULL AND agent_name IS NOT NULL
GROUP BY session_id, agent_name;

CREATE UNIQUE INDEX bridge_session_agent_pk
    ON marts.bridge_session_agent (session_id, agent_name);

-- bridge_session_hook: hook executions, at hook_name grain (e.g. PreToolUse:Bash).
CREATE MATERIALIZED VIEW marts.bridge_session_hook AS
SELECT session_id, hook_name, COUNT(*) AS executions
FROM raw.events
WHERE event_name = 'hook_execution_complete' AND session_id IS NOT NULL AND hook_name IS NOT NULL
GROUP BY session_id, hook_name;

CREATE UNIQUE INDEX bridge_session_hook_pk
    ON marts.bridge_session_hook (session_id, hook_name);

-- migrate:down

DROP MATERIALIZED VIEW IF EXISTS marts.bridge_session_hook;
DROP MATERIALIZED VIEW IF EXISTS marts.bridge_session_agent;
DROP MATERIALIZED VIEW IF EXISTS marts.bridge_session_plugin;
DROP MATERIALIZED VIEW IF EXISTS marts.bridge_session_mcp;
DROP MATERIALIZED VIEW IF EXISTS marts.bridge_session_skill;
