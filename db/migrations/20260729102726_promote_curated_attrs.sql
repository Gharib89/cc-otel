-- migrate:up
-- noqa: disable=LT05,LT14

-- The #350 curation pass: 25 registry rows flip kept -> promoted (#357 Group A,
-- #358 Group B, #359 Group C), under the density posture and one-attr-path-per-column
-- rule settled in #354.
--
-- Hand-authored, and landing *before* the generated migration, because spec_sync's
-- registry diff is a set diff over the 10-field RegistryRow: an in-place status edit
-- reads as a missing_row plus an orphan_row, and generate_migration refuses orphans
-- (curation runbook section 3). The generated sibling carries the raw.* ADD COLUMNs
-- and the nine genuinely new kept rows.

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'hook_source',
    data_type = 'TEXT',
    description = 'Where the hook came from (settings/pluginHook/...).',
    useful_for = 'attributes hook load to plugins, which the plugin columns cannot',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#359); populates across three hook families'
WHERE signal = 'events' AND signal_name = '*' AND attr_path = 'hook_source';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'num_hooks',
    data_type = 'SMALLINT',
    description = 'Hooks matched for the event.',
    useful_for = 'how much hook machinery the fleet runs',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#359); populates across hook_execution_start / hook_execution_complete / hook_registered, not one family'
WHERE signal = 'events' AND signal_name = '*' AND attr_path = 'num_hooks';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'status_code',
    data_type = 'SMALLINT',
    useful_for = 'decomposes fact_api_error_rate: 429 (tier) vs 529 (overload) vs 500 (fault)',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#359); 24 records / 6 seats -- survives the near-zero-counter rule because it decomposes a rate the report already publishes'
WHERE signal = 'events' AND signal_name = '*' AND attr_path = 'status_code';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'terminal_type',
    data_type = 'TEXT',
    description = 'Terminal app type (terminal / VS Code / non-interactive).',
    useful_for = 'surface split; non-interactive is adoption, not noise',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#357): 15 of 19 seats run non-interactive'
WHERE signal = 'events' AND signal_name = '*' AND attr_path = 'terminal.type';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'workflow_name',
    data_type = 'TEXT',
    description = 'Workflow name on workflow-spawned agents.',
    useful_for = 'dynamic-workflow adoption (a figure, not a slicer)',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#357); workflow.run_id stays kept as high-cardinality run identity'
WHERE signal = 'events' AND signal_name = '*' AND attr_path = 'workflow.name';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'num_success',
    data_type = 'SMALLINT',
    description = 'Hooks that succeeded.',
    useful_for = 'with num_hooks, states the failure count exactly',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#359); the failure *mode* split stays kept -- num_hooks - num_success equals the three mode counters on all 17,077 records'
WHERE signal = 'events' AND signal_name = 'hook_execution_complete' AND attr_path = 'num_success';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'total_duration_ms',
    data_type = 'BIGINT',
    description = 'Total time across the hooks run for one event.',
    useful_for = 'hook overhead: bridge_session_hook has executions and no time',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#359); own column, not an alias of duration_ms -- #354 reversed that reuse. A sum over N hooks is not one operation''s latency'
WHERE signal = 'events' AND signal_name = 'hook_execution_complete' AND attr_path = 'total_duration_ms';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'mcp_connection_server_name',
    data_type = 'TEXT',
    description = 'MCP server display name on the connection event.',
    useful_for = 'installed-and-idle MCP servers: ~25 connect, 8 are ever paid for',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#358); a wider population than mcp_server_name, and display names not slugs -- a join needs an explicit ''.''/'' ''/'':'' -> ''_'' transform'
WHERE signal = 'events' AND signal_name = 'mcp_server_connection' AND attr_path = 'server_name';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'mcp_connection_server_scope',
    data_type = 'TEXT',
    description = 'MCP server scope on the connection event (claudeai/dynamic/project/local/user).',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#358); its own column, not shared with tool_result''s mcp_server_scope -- distinct attr paths split under #354''s one-path rule'
WHERE signal = 'events' AND signal_name = 'mcp_server_connection' AND attr_path = 'server_scope';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'mcp_connection_status',
    data_type = 'TEXT',
    description = 'MCP connection status (connected/disconnected/failed).',
    useful_for = 'separates idle from broken -- retire vs fix',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#358); failed on 9 seats, and it carries what error_code cannot'
WHERE signal = 'events' AND signal_name = 'mcp_server_connection' AND attr_path = 'status';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'mcp_transport_type',
    data_type = 'TEXT',
    description = 'MCP transport (claudeai-proxy/stdio/ws-ide).',
    useful_for = 'hosted vs local; what IS must allow through the network',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#358); server-static, promoted only because no server dimension exists today'
WHERE signal = 'events' AND signal_name = 'mcp_server_connection' AND attr_path = 'transport_type';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'plugin_scope',
    data_type = 'TEXT',
    description = 'Plugin scope (official/user-local).',
    useful_for = 'per-seat fact: the same plugin loads official on some seats, user-local on others',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#358)'
WHERE signal = 'events' AND signal_name = 'plugin_loaded' AND attr_path = 'plugin.scope';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'plugin_version',
    data_type = 'TEXT',
    useful_for = 'staleness spread across seats',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#358); 85% fill'
WHERE signal = 'events' AND signal_name = 'plugin_loaded' AND attr_path = 'plugin.version';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'skill_invocation_trigger',
    data_type = 'TEXT',
    description = 'Skill invocation trigger (user-slash/claude-proactive/nested-skill).',
    useful_for = 'human pull vs model push; a slicer, never a filter baked into a measure',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#358); deliberately not a third vocabulary on `trigger`'
WHERE signal = 'events' AND signal_name = 'skill_activated' AND attr_path = 'invocation_trigger';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'skill_source',
    data_type = 'TEXT',
    description = 'Skill source (userSettings/projectSettings/plugin/bundled/builtin).',
    useful_for = 'do skills spread through the team or stay personal',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#358); sparsest column in the batch at 0.25% populated, four times denser than the shipped mention_type (#354)'
WHERE signal = 'events' AND signal_name = 'skill_activated' AND attr_path = 'skill.source';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'agent_type',
    data_type = 'TEXT',
    description = 'Subagent type on the completion event.',
    useful_for = 'subagent run counts (query_source counts requests, not runs)',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#358); own column, not an alias of agent_name -- #354 reversed that reuse: it was a density compromise and density is free here'
WHERE signal = 'events' AND signal_name = 'subagent_completed' AND attr_path = 'agent_type';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'subagent_is_async',
    data_type = 'BOOLEAN',
    description = 'Background-agent flag.',
    useful_for = 'nothing else records background-agent use',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#358)'
WHERE signal = 'events' AND signal_name = 'subagent_completed' AND attr_path = 'is_async';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'subagent_total_tokens',
    data_type = 'BIGINT',
    description = 'Tokens consumed by the subagent run.',
    useful_for = 'query_source=''agent:custom'' collapses every custom agent into one bucket',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#358); own column, never a reuse of input/output_tokens -- those are per-request and a SUM across both families would double-count'
WHERE signal = 'events' AND signal_name = 'subagent_completed' AND attr_path = 'total_tokens';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'subagent_tool_uses',
    data_type = 'BIGINT',
    description = 'Tool calls made by the subagent.',
    useful_for = 'irreducible: tool_decision.query_source is NULL on all rows',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#358)'
WHERE signal = 'events' AND signal_name = 'subagent_completed' AND attr_path = 'total_tool_uses';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'decision_source',
    data_type = 'TEXT',
    description = 'Who authorised the tool call (config/hook/user_temporary/...).',
    useful_for = 'permission friction: user_temporary on 12 of 13 seats',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#359); `decision` says accept/reject, nothing said who authorised'
WHERE signal = 'events' AND signal_name = 'tool_result' AND attr_path = 'decision_source';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'error_type',
    data_type = 'TEXT',
    description = 'Tool failure category (not the message).',
    useful_for = 'the only route to a failure taxonomy -- free-text `error` is denied',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#359); ShellError 1,108 across 15 seats'
WHERE signal = 'events' AND signal_name = 'tool_result' AND attr_path = 'error_type';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'mcp_server_scope',
    data_type = 'TEXT',
    description = 'MCP server scope on the tool-result event.',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#358); shared vocabulary with the connection event''s server_scope, separate column (#354)'
WHERE signal = 'events' AND signal_name = 'tool_result' AND attr_path = 'mcp_server_scope';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'terminal_type',
    data_type = 'TEXT',
    description = 'Terminal app type (terminal / VS Code / non-interactive).',
    useful_for = 'surface split; non-interactive is adoption, not noise',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#357): 15 of 19 seats run non-interactive'
WHERE signal = 'metrics' AND signal_name = '*' AND attr_path = 'terminal.type';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'os_type',
    data_type = 'TEXT',
    description = 'OS type; carries the WSL-vs-native-Windows split on its own.',
    useful_for = 'fleet composition figure',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#357); wsl.version is exactly collinear with os_type=''linux'''
WHERE signal = 'resource' AND signal_name = '*' AND attr_path = 'os.type';

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'service_name',
    data_type = 'TEXT',
    description = 'Emitting surface: claude-code / claude-code-desktop / cowork.',
    useful_for = 'desktop adoption; the only key separating the three surfaces',
    decided_at = '2026-07-29',
    notes = 'promoted from kept (#357); resource-only, so kind=derived reaches both raw tables'
WHERE signal = 'resource' AND signal_name = '*' AND attr_path = 'service.name';

-- migrate:down

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Hook source.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = '*' AND attr_path = 'hook_source';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Hook count for the event.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = '*' AND attr_path = 'num_hooks';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = '*' AND attr_path = 'status_code';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Terminal app type.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = '*' AND attr_path = 'terminal.type';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Workflow name (custom unless details).',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = 'v2.1.202+'
WHERE signal = 'events' AND signal_name = '*' AND attr_path = 'workflow.name';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Successful hooks.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'hook_execution_complete' AND attr_path = 'num_success';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Total hook duration.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'hook_execution_complete' AND attr_path = 'total_duration_ms';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'MCP server name (details).',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'mcp_server_connection' AND attr_path = 'server_name';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Server scope.',
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'mcp_server_connection' AND attr_path = 'server_scope';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Connection status.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'mcp_server_connection' AND attr_path = 'status';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Transport type.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'mcp_server_connection' AND attr_path = 'transport_type';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Plugin scope.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'plugin_loaded' AND attr_path = 'plugin.scope';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'plugin_loaded' AND attr_path = 'plugin.version';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Skill invocation trigger.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'skill_activated' AND attr_path = 'invocation_trigger';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Skill source.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'skill_activated' AND attr_path = 'skill.source';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Subagent type.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'subagent_completed' AND attr_path = 'agent_type';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Async subagent flag.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'subagent_completed' AND attr_path = 'is_async';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Subagent total tokens.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'subagent_completed' AND attr_path = 'total_tokens';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Subagent tool-use count.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'subagent_completed' AND attr_path = 'total_tool_uses';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Decision source.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'tool_result' AND attr_path = 'decision_source';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Error category (not the message).',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'tool_result' AND attr_path = 'error_type';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'MCP server scope.',
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'tool_result' AND attr_path = 'mcp_server_scope';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Terminal app type.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'metrics' AND signal_name = '*' AND attr_path = 'terminal.type';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'OS type.',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'resource' AND signal_name = '*' AND attr_path = 'os.type';

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    description = 'Service name (claude-code).',
    useful_for = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'resource' AND signal_name = '*' AND attr_path = 'service.name';
