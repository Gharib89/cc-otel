-- migrate:up
-- spec_sync: promotion_bundle
-- noqa: disable=LT05,LT14

ALTER TABLE raw.metrics ADD COLUMN terminal_type TEXT;
ALTER TABLE raw.metrics ADD COLUMN service_name TEXT;
ALTER TABLE raw.metrics ADD COLUMN os_type TEXT;
ALTER TABLE raw.events ADD COLUMN service_name TEXT;
ALTER TABLE raw.events ADD COLUMN os_type TEXT;
ALTER TABLE raw.events ADD COLUMN terminal_type TEXT;
ALTER TABLE raw.events ADD COLUMN workflow_name TEXT;
ALTER TABLE raw.events ADD COLUMN mcp_connection_server_name TEXT;
ALTER TABLE raw.events ADD COLUMN mcp_connection_status TEXT;
ALTER TABLE raw.events ADD COLUMN mcp_transport_type TEXT;
ALTER TABLE raw.events ADD COLUMN mcp_connection_server_scope TEXT;
ALTER TABLE raw.events ADD COLUMN mcp_server_scope TEXT;
ALTER TABLE raw.events ADD COLUMN agent_type TEXT;
ALTER TABLE raw.events ADD COLUMN subagent_is_async BOOLEAN;
ALTER TABLE raw.events ADD COLUMN subagent_tool_uses BIGINT;
ALTER TABLE raw.events ADD COLUMN subagent_total_tokens BIGINT;
ALTER TABLE raw.events ADD COLUMN plugin_scope TEXT;
ALTER TABLE raw.events ADD COLUMN plugin_version TEXT;
ALTER TABLE raw.events ADD COLUMN skill_invocation_trigger TEXT;
ALTER TABLE raw.events ADD COLUMN skill_source TEXT;
ALTER TABLE raw.events ADD COLUMN decision_source TEXT;
ALTER TABLE raw.events ADD COLUMN error_type TEXT;
ALTER TABLE raw.events ADD COLUMN status_code SMALLINT;
ALTER TABLE raw.events ADD COLUMN num_hooks SMALLINT;
ALTER TABLE raw.events ADD COLUMN num_success SMALLINT;
ALTER TABLE raw.events ADD COLUMN hook_source TEXT;
ALTER TABLE raw.events ADD COLUMN total_duration_ms BIGINT;
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('events', 'assistant_response', 'message.uuid', 'kept', NULL, NULL, 'Message UUID.', NULL, '2026-07-29', 'kept basis collinear (#359): covered by the promoted prompt_id, which reaches all three families');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('events', 'feedback_survey', 'event_origin', 'kept', NULL, NULL, 'Where the survey event originated.', NULL, '2026-07-29', 'kept basis thin (#370): surfaced by the post-#369 sweep with no group verdict; the whole feedback_survey family is a 28 -> 21 -> 5 funnel answering Anthropic''s question about survey uptake, not ITWorx''s about adoption (#359)');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('events', 'feedback_survey', 'event_origin_server', 'kept', NULL, NULL, 'Server that originated the survey event.', NULL, '2026-07-29', 'kept basis thin (#370): surfaced by the post-#369 sweep with no group verdict; same family reading');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('events', 'subagent_completed', 'final_model', 'kept', NULL, NULL, 'Model the subagent finished on.', NULL, '2026-07-29', 'kept basis collinear (#358): api_request already carries `model` alongside the agent-bearing query_source, so model-per-agent exists at request grain');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('events', 'subagent_completed', 'model_swapped', 'kept', NULL, NULL, 'Whether the subagent''s model changed mid-run.', NULL, '2026-07-29', '#370: kept basis UNMEASURED -- surfaced by the post-#369 sweep, after the #351 profiling run, so no group measured it. Kept because no report states a rate it is the numerator of (#359 near-zero-counter rule); revisit under #366');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('events', 'tool_decision', 'tool_source', 'kept', NULL, NULL, 'Where the tool came from (builtin/mcp/sdk_host_builtin_mcp).', NULL, '2026-07-29', 'kept basis collinear (#358): redundant with the promoted tool_name=''mcp_tool'' -- 1,027 rows both ways, adds 34 of 49,250 (0.07%)');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('events', 'user_prompt', 'message.uuid', 'kept', NULL, NULL, 'Message UUID.', NULL, '2026-07-29', 'kept basis collinear (#359): covered by the promoted prompt_id');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('metrics', 'claude_code.cost.usage', 'mcp_server.name', 'kept', NULL, NULL, 'MCP server attribution.', NULL, '2026-07-29', 'kept basis collinear (#358): exactly redundant with raw.events.api_request -- 20 (server, tool) pairs both sides, 0 either-only, cost within 0.04%');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('metrics', 'claude_code.cost.usage', 'mcp_tool.name', 'kept', NULL, NULL, 'MCP tool attribution.', NULL, '2026-07-29', 'kept basis collinear (#358): same pair; promoting would mint a second, ambiguous MCP-cost path (ADR-0008)');

-- migrate:down

DELETE FROM meta.column_registry WHERE signal = 'metrics' AND signal_name = 'claude_code.cost.usage' AND attr_path = 'mcp_tool.name';
DELETE FROM meta.column_registry WHERE signal = 'metrics' AND signal_name = 'claude_code.cost.usage' AND attr_path = 'mcp_server.name';
DELETE FROM meta.column_registry WHERE signal = 'events' AND signal_name = 'user_prompt' AND attr_path = 'message.uuid';
DELETE FROM meta.column_registry WHERE signal = 'events' AND signal_name = 'tool_decision' AND attr_path = 'tool_source';
DELETE FROM meta.column_registry WHERE signal = 'events' AND signal_name = 'subagent_completed' AND attr_path = 'model_swapped';
DELETE FROM meta.column_registry WHERE signal = 'events' AND signal_name = 'subagent_completed' AND attr_path = 'final_model';
DELETE FROM meta.column_registry WHERE signal = 'events' AND signal_name = 'feedback_survey' AND attr_path = 'event_origin_server';
DELETE FROM meta.column_registry WHERE signal = 'events' AND signal_name = 'feedback_survey' AND attr_path = 'event_origin';
DELETE FROM meta.column_registry WHERE signal = 'events' AND signal_name = 'assistant_response' AND attr_path = 'message.uuid';
ALTER TABLE raw.events DROP COLUMN total_duration_ms;
ALTER TABLE raw.events DROP COLUMN hook_source;
ALTER TABLE raw.events DROP COLUMN num_success;
ALTER TABLE raw.events DROP COLUMN num_hooks;
ALTER TABLE raw.events DROP COLUMN status_code;
ALTER TABLE raw.events DROP COLUMN error_type;
ALTER TABLE raw.events DROP COLUMN decision_source;
ALTER TABLE raw.events DROP COLUMN skill_source;
ALTER TABLE raw.events DROP COLUMN skill_invocation_trigger;
ALTER TABLE raw.events DROP COLUMN plugin_version;
ALTER TABLE raw.events DROP COLUMN plugin_scope;
ALTER TABLE raw.events DROP COLUMN subagent_total_tokens;
ALTER TABLE raw.events DROP COLUMN subagent_tool_uses;
ALTER TABLE raw.events DROP COLUMN subagent_is_async;
ALTER TABLE raw.events DROP COLUMN agent_type;
ALTER TABLE raw.events DROP COLUMN mcp_server_scope;
ALTER TABLE raw.events DROP COLUMN mcp_connection_server_scope;
ALTER TABLE raw.events DROP COLUMN mcp_transport_type;
ALTER TABLE raw.events DROP COLUMN mcp_connection_status;
ALTER TABLE raw.events DROP COLUMN mcp_connection_server_name;
ALTER TABLE raw.events DROP COLUMN workflow_name;
ALTER TABLE raw.events DROP COLUMN terminal_type;
ALTER TABLE raw.events DROP COLUMN os_type;
ALTER TABLE raw.events DROP COLUMN service_name;
ALTER TABLE raw.metrics DROP COLUMN os_type;
ALTER TABLE raw.metrics DROP COLUMN service_name;
ALTER TABLE raw.metrics DROP COLUMN terminal_type;
