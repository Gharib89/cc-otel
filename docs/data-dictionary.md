# cc-otel — Data Dictionary

> Generated **2026-07-29** by `tools.gen_data_dictionary` against `cc_otel`.
> Row counts are a live snapshot; treat them as representative, not exact.

Descriptions come from `meta.column_registry` (the curated catalogue, #16); profiling
stats are live from `raw.metrics` / `raw.events`. Kept (blob-only) and denied (stripped)
keys have no Postgres column, so they are listed without live stats — use `tools.sweep`
to see what is actually present in the blob reservoir.

**Regenerate:** `uv run python -m tools.gen_data_dictionary` (commit the result).

## Tables profiled

| table | rows |
|---|---:|
| `raw.metrics` | 1,763,307 |
| `raw.events` | 361,434 |

## `raw.metrics`

### Row counts by signal name

| name | rows | % | first seen | last seen |
|---|---:|---:|---|---|
| `claude_code.token.usage` | 361,216 | 20.5% | 2026-05-24 | 2026-07-29 |
| `claude_code.usage.utilization` | 260,604 | 14.8% | 2026-05-24 | 2026-07-29 |
| `claude_code.usage.reset_in_seconds` | 260,601 | 14.8% | 2026-05-24 | 2026-07-29 |
| `claude_code.context.input_tokens` | 131,353 | 7.4% | 2026-05-24 | 2026-07-16 |
| `claude_code.context.output_tokens` | 131,353 | 7.4% | 2026-05-24 | 2026-07-16 |
| `claude_code.session.duration_ms` | 131,350 | 7.4% | 2026-05-24 | 2026-07-16 |
| `claude_code.session.api_duration_ms` | 131,350 | 7.4% | 2026-05-24 | 2026-07-16 |
| `claude_code.context.used_percentage` | 129,347 | 7.3% | 2026-05-24 | 2026-07-16 |
| `claude_code.cost.usage` | 90,304 | 5.1% | 2026-05-24 | 2026-07-29 |
| `claude_code.active_time.total` | 76,784 | 4.4% | 2026-05-24 | 2026-07-29 |
| `claude_code.lines_of_code.count` | 33,890 | 1.9% | 2026-05-24 | 2026-07-29 |
| `claude_code.code_edit_tool.decision` | 18,601 | 1.1% | 2026-05-24 | 2026-07-29 |
| `claude_code.commit.count` | 3,271 | 0.2% | 2026-05-24 | 2026-07-29 |
| `claude_code.session.count` | 2,859 | 0.2% | 2026-05-24 | 2026-07-29 |
| `claude_code.pull_request.count` | 424 | 0.0% | 2026-05-24 | 2026-07-29 |

### Promoted columns

| column | type | non-null % | unique % | distinct | description | useful for |
|---|---|---:|---:|---:|---|---|
| `ts` | timestamp with time zone | 100.0% | 13.5% | 237,341 | Metric data-point timestamp. | time grain |
| `metric_name` | text | 100.0% | 0.0% | 15 | OTel instrument name. | signal routing |
| `metric_type` | text | 100.0% | 0.0% | 2 | Instrument kind: gauge/sum/histogram. | temporality handling |
| `value` | double precision | 100.0% | 31.4% | 553,412 | Numeric data-point value (delta counters). | all measures |
| `count` | bigint | 0.0% | — | 0 | Pre-aggregated count on histogram instruments. |  |
| `value_kind` | text | 100.0% | 0.0% | 2 | Derived: gauge_last/sum_delta/sum_cumulative/hist_sum. | delta-only staging filter |
| `user_email` | text | 100.0% | 0.0% | 22 | Developer identity (normalized lowercase/trim). | dim_user join |
| `user_account_id` | text | 33.9% | 0.0% | 23 | Anthropic tagged account id. |  |
| `organization_id` | text | 33.3% | 0.0% | 3 | Organization UUID. |  |
| `session_id` | uuid | 100.0% | 0.2% | 3,517 | Claude Code session UUID. | session facts |
| `model` | text | 93.3% | 0.0% | 19 | Model id (usage/cost/LOC metrics). | dim_model |
| `type_label` | text | 26.8% | 0.0% | 8 | Active-time type: user (keyboard) / cli (tools+AI). | active time split |
| `tool_name` | text | 1.1% | 0.0% | 2 | Edit/Write/NotebookEdit. | fact_edit_decision |
| `decision` | text | 1.1% | 0.0% | 2 | accept / reject. | acceptance rate |
| `source` | text | 1.1% | 0.0% | 6 | Decision source: config/hook/user_*. | auto-vs-human split |
| `language` | text | 1.1% | 0.1% | 23 | Detected language. | language mix |
| `usage_window` | text | 29.6% | 0.0% | 3 | Rate-limit window (5h/7d/...). | fact_usage_window |
| `cc_version` | text | 33.3% | 0.0% | 62 | Claude Code version. | install health |
| `query_source` | text | 25.6% | 0.0% | 3 | Request origin: main/subagent/auxiliary. |  |
| `effort` | text | 90.3% | 0.0% | 5 | Reasoning-effort level. |  |
| `speed` | text | 0.0% | — | 0 | fast when fast-mode. |  |
| `agent_name` | text | 5.2% | 0.0% | 16 | Agent attribution (custom collapses). |  |
| `skill_name` | text | 9.8% | 0.1% | 123 | Skill attribution. |  |
| `plugin_name` | text | 3.8% | 0.0% | 10 | Plugin attribution. |  |
| `marketplace_name` | text | 2.8% | 0.0% | 1 | Marketplace attribution. |  |
| `start_type` | text | 0.2% | 0.1% | 3 | fresh/resume/continue/agents_view. | fact_session |
| `scope_name` | text | 100.0% | 0.0% | 2 | OTel instrumentation scope. | wrapper-vs-native split |
| `scope_version` | text | 33.3% | 0.0% | 56 | Instrumentation scope version. |  |
| `process_owner` | text | 0.0% | 100.0% | 1 | OS account the Claude Code process runs under (e.g. a Windows username). | account sharing: a row whose process_owner disagrees with user_email is one person emitting under another person's account |
| `terminal_type` | text | 0.0% | — | 0 | Terminal app type (terminal / VS Code / non-interactive). | surface split; non-interactive is adoption, not noise |
| `service_name` | text | 0.0% | — | 0 | Emitting surface: claude-code / claude-code-desktop / cowork. | desktop adoption; the only key separating the three surfaces |
| `os_type` | text | 0.0% | — | 0 | OS type; carries the WSL-vs-native-Windows split on its own. | fleet composition figure |

## `raw.events`

### Row counts by signal name

| name | rows | % | first seen | last seen |
|---|---:|---:|---|---|
| `api_request` | 76,332 | 21.1% | 2026-05-24 | 2026-07-29 |
| `tool_decision` | 70,780 | 19.6% | 2026-05-24 | 2026-07-29 |
| `tool_result` | 58,417 | 16.2% | 2026-07-14 | 2026-07-29 |
| `hook_execution_complete` | 53,488 | 14.8% | 2026-05-24 | 2026-07-29 |
| `hook_execution_start` | 49,339 | 13.7% | 2026-05-24 | 2026-07-29 |
| `assistant_response` | 34,087 | 9.4% | 2026-06-26 | 2026-07-29 |
| `plugin_loaded` | 5,708 | 1.6% | 2026-05-24 | 2026-07-29 |
| `hook_registered` | 4,917 | 1.4% | 2026-05-24 | 2026-07-29 |
| `user_prompt` | 3,744 | 1.0% | 2026-07-14 | 2026-07-29 |
| `subagent_completed` | 1,265 | 0.3% | 2026-05-24 | 2026-07-29 |
| `mcp_server_connection` | 1,219 | 0.3% | 2026-07-14 | 2026-07-29 |
| `skill_activated` | 962 | 0.3% | 2026-06-09 | 2026-07-29 |
| `permission_mode_changed` | 402 | 0.1% | 2026-05-25 | 2026-07-28 |
| `at_mention` | 260 | 0.1% | 2026-07-14 | 2026-07-29 |
| `feedback_survey` | 180 | 0.0% | 2026-05-24 | 2026-07-29 |
| `internal_error` | 126 | 0.0% | 2026-05-25 | 2026-07-29 |
| `api_error` | 85 | 0.0% | 2026-05-25 | 2026-07-28 |
| `compaction` | 59 | 0.0% | 2026-07-16 | 2026-07-29 |
| `plugin_installed` | 26 | 0.0% | 2026-06-04 | 2026-07-28 |
| `api_retries_exhausted` | 21 | 0.0% | 2026-06-05 | 2026-07-27 |
| `auth` | 15 | 0.0% | 2026-07-15 | 2026-07-28 |
| `api_refusal` | 2 | 0.0% | 2026-07-18 | 2026-07-29 |

### Promoted columns

| column | type | non-null % | unique % | distinct | description | useful for |
|---|---|---:|---:|---:|---|---|
| `event_time` | timestamp with time zone | 100.0% | 90.8% | 328,042 | Log-record timestamp. | time grain |
| `event_name` | text | 100.0% | 0.0% | 22 | Event name. | signal routing |
| `severity` | text | 0.0% | — | 0 | Log severity text. |  |
| `body` | text | 100.0% | 0.0% | 22 | OTLP log-record body (event-name string for CC events). |  |
| `user_email` | text | 100.0% | 0.0% | 22 | Developer identity (normalized lowercase/trim). | dim_user join |
| `user_account_id` | text | 100.0% | 0.0% | 22 | Anthropic tagged account id. |  |
| `organization_id` | text | 100.0% | 0.0% | 3 | Organization UUID. |  |
| `session_id` | uuid | 100.0% | 0.7% | 2,654 | Claude Code session UUID. | session facts |
| `prompt_id` | uuid | 96.0% | 3.1% | 10,728 | Prompt UUID. | prompt correlation |
| `model` | text | 30.9% | 0.0% | 10 | Model id (api_request/assistant_response). | fact_api_usage |
| `tool_name` | text | 35.7% | 0.0% | 33 | Tool name (tool_decision/tool_result; incl. mcp__*). | bridge_session_mcp |
| `duration_ms` | bigint | 38.0% | 25.3% | 34,809 | Failed request duration. |  |
| `input_tokens` | bigint | 21.1% | 2.6% | 1,988 | Prompt tokens. | fact_api_usage |
| `output_tokens` | bigint | 21.1% | 7.7% | 5,840 | Completion tokens. | fact_api_usage |
| `cache_creation_tokens` | bigint | 21.1% | 15.3% | 11,704 | Cache-write tokens. | fact_api_usage |
| `cache_read_tokens` | bigint | 21.1% | 83.8% | 63,943 | Cache-read tokens. | fact_api_usage |
| `cost_usd` | double precision | 21.1% | 97.3% | 74,257 | Estimated cost. |  |
| `cc_version` | text | 100.0% | 0.0% | 61 | Claude Code version. | install health |
| `event_sequence` | bigint | 100.0% | 3.7% | 13,484 | Per-session event ordinal. |  |
| `request_id` | text | 30.6% | 69.1% | 76,405 | Anthropic API request id. |  |
| `speed` | text | 21.1% | 0.0% | 1 | fast/normal. |  |
| `effort` | text | 20.3% | 0.0% | 5 | Reasoning-effort level. | fact_api_usage |
| `query_source` | text | 30.6% | 0.0% | 22 | Request origin. | fact_api_usage |
| `prompt_length` | bigint | 1.0% | 22.4% | 838 | Prompt length in chars. | non-empty session |
| `command_name` | text | 0.2% | 7.9% | 69 | Slash-command name. |  |
| `command_source` | text | 0.2% | 0.2% | 2 | builtin/custom/mcp. |  |
| `hook_name` | text | 28.4% | 0.1% | 129 | Hook name (hook_execution_*/hook_registered). | bridge_session_hook |
| `hook_event` | text | 29.8% | 0.0% | 10 | Hook trigger event. |  |
| `from_mode` | text | 0.1% | 1.0% | 4 | Permission mode before change. |  |
| `to_mode` | text | 0.1% | 1.0% | 4 | Permission mode after change. |  |
| `trigger` | text | 0.1% | 1.1% | 5 | Compaction trigger (auto/manual). |  |
| `skill_name` | text | 8.1% | 0.5% | 138 | Skill name (skill_activated/api_request). | bridge_session_skill |
| `agent_name` | text | 4.7% | 0.1% | 14 | Agent attribution (api_request). | bridge_session_agent |
| `plugin_name` | text | 5.3% | 0.2% | 41 | Plugin name (plugin_loaded). | bridge_session_plugin |
| `marketplace_name` | text | 4.0% | 0.1% | 15 | Marketplace attribution. |  |
| `mcp_server_name` | text | 1.1% | 0.4% | 16 | MCP server attribution (api_request). | bridge_session_mcp |
| `mcp_tool_name` | text | 1.1% | 0.8% | 29 | MCP tool attribution (api_request). |  |
| `mention_type` | text | 0.1% | 1.2% | 3 | @-mention target type. |  |
| `success_bool` | boolean | 16.3% | 0.0% | 2 | Success flag where reported. |  |
| `tool_use_id` | text | 35.7% | 54.8% | 70,784 | Tool invocation id. |  |
| `decision` | text | 19.6% | 0.0% | 2 | accept / reject (tool_decision). |  |
| `source` | text | 19.6% | 0.0% | 6 | Decision source (tool_decision). |  |
| `scope_name` | text | 100.0% | 0.0% | 1 | Instrumentation scope. |  |
| `scope_version` | text | 100.0% | 0.0% | 55 | Scope version. |  |
| `severity_number` | smallint | 0.0% | — | 0 | Log severity number. |  |
| `log_trace_id` | text | 23.9% | 7.6% | 6,618 | Trace id if present. |  |
| `log_span_id` | text | 23.9% | 28.5% | 24,621 | Span id if present. |  |
| `dropped_attributes_count` | integer | 21.1% | 0.0% | 1 | Dropped-attribute count. | ingest QA |
| `process_owner` | text | 0.0% | 25.0% | 1 | OS account the Claude Code process runs under (e.g. a Windows username). | account sharing: a row whose process_owner disagrees with user_email is one person emitting under another person's account |
| `service_name` | text | 0.0% | — | 0 | Emitting surface: claude-code / claude-code-desktop / cowork. | desktop adoption; the only key separating the three surfaces |
| `os_type` | text | 0.0% | — | 0 | OS type; carries the WSL-vs-native-Windows split on its own. | fleet composition figure |
| `terminal_type` | text | 0.0% | — | 0 | Terminal app type (terminal / VS Code / non-interactive). | surface split; non-interactive is adoption, not noise |
| `workflow_name` | text | 0.0% | — | 0 | Workflow name on workflow-spawned agents. | dynamic-workflow adoption (a figure, not a slicer) |
| `mcp_connection_server_name` | text | 0.0% | — | 0 | MCP server display name on the connection event. | installed-and-idle MCP servers: ~25 connect, 8 are ever paid for |
| `mcp_connection_status` | text | 0.0% | — | 0 | MCP connection status (connected/disconnected/failed). | separates idle from broken -- retire vs fix |
| `mcp_transport_type` | text | 0.0% | — | 0 | MCP transport (claudeai-proxy/stdio/ws-ide). | hosted vs local; what IS must allow through the network |
| `mcp_connection_server_scope` | text | 0.0% | — | 0 | MCP server scope on the connection event (claudeai/dynamic/project/local/user). |  |
| `mcp_server_scope` | text | 0.0% | — | 0 | MCP server scope on the tool-result event. |  |
| `agent_type` | text | 0.0% | — | 0 | Subagent type on the completion event. | subagent run counts (query_source counts requests, not runs) |
| `subagent_is_async` | boolean | 0.0% | — | 0 | Background-agent flag. | nothing else records background-agent use |
| `subagent_tool_uses` | bigint | 0.0% | — | 0 | Tool calls made by the subagent. | irreducible: tool_decision.query_source is NULL on all rows |
| `subagent_total_tokens` | bigint | 0.0% | — | 0 | Tokens consumed by the subagent run. | query_source='agent:custom' collapses every custom agent into one bucket |
| `plugin_scope` | text | 0.0% | — | 0 | Plugin scope (official/user-local). | per-seat fact: the same plugin loads official on some seats, user-local on others |
| `plugin_version` | text | 0.0% | — | 0 | Plugin version. | staleness spread across seats |
| `skill_invocation_trigger` | text | 0.0% | — | 0 | Skill invocation trigger (user-slash/claude-proactive/nested-skill). | human pull vs model push; a slicer, never a filter baked into a measure |
| `skill_source` | text | 0.0% | — | 0 | Skill source (userSettings/projectSettings/plugin/bundled/builtin). | do skills spread through the team or stay personal |
| `decision_source` | text | 0.0% | — | 0 | Who authorised the tool call (config/hook/user_temporary/...). | permission friction: user_temporary on 12 of 13 seats |
| `error_type` | text | 0.0% | — | 0 | Tool failure category (not the message). | the only route to a failure taxonomy -- free-text `error` is denied |
| `status_code` | smallint | 0.0% | — | 0 | HTTP status code. | decomposes fact_api_error_rate: 429 (tier) vs 529 (overload) vs 500 (fault) |
| `num_hooks` | smallint | 0.0% | — | 0 | Hooks matched for the event. | how much hook machinery the fleet runs |
| `num_success` | smallint | 0.0% | — | 0 | Hooks that succeeded. | with num_hooks, states the failure count exactly |
| `hook_source` | text | 0.0% | — | 0 | Where the hook came from (settings/pluginHook/...). | attributes hook load to plugins, which the plugin columns cannot |
| `total_duration_ms` | bigint | 0.0% | — | 0 | Total time across the hooks run for one event. | hook overhead: bridge_session_hook has executions and no time |

## Kept & denied attributes (not in Postgres)

`kept` = blob reservoir only; `denied` = stripped by the sink wherever seen.

| signal | signal name | attr path | status | description | useful for |
|---|---|---|---|---|---|
| events | `*` | `bash_command` | denied | Bash command. |  |
| events | `*` | `error` | denied | Error message. |  |
| events | `*` | `file_path` | denied | File path. |  |
| events | `*` | `full_command` | denied | Full command line. |  |
| events | `api_request_body` | `body` | denied | Raw API request body. |  |
| events | `api_request_body` | `body_ref` | denied | Raw API request body file ref. |  |
| events | `api_response_body` | `body` | denied | Raw API response body. |  |
| events | `api_response_body` | `body_ref` | denied | Raw API response body file ref. |  |
| events | `assistant_response` | `response` | denied | Assistant response text. |  |
| events | `feedback_survey` | `response` | denied | Survey free-text response. |  |
| events | `tool_decision` | `tool_parameters` | denied | Tool args JSON (details-gated). |  |
| events | `tool_result` | `tool_input` | denied | Tool args JSON (details-gated). |  |
| events | `tool_result` | `tool_parameters` | denied | Tool args JSON (details-gated). |  |
| events | `user_prompt` | `prompt` | denied | Prompt text. |  |
| events | `*` | `attempt` | kept | API attempt number. |  |
| events | `*` | `client_request_id` | kept | Client request id. |  |
| events | `*` | `cost_usd_micros` | kept | Cost in micros. |  |
| events | `*` | `event.timestamp` | kept | ISO event timestamp. |  |
| events | `*` | `identity.source` | kept | Identity source (e.g. gateway-oidc). |  |
| events | `*` | `managed_only` | kept | Managed-only flag. |  |
| events | `*` | `plugin_id_hash` | kept | Plugin id hash. |  |
| events | `*` | `safe_mode` | kept | Safe-mode flag. |  |
| events | `*` | `stop_reason` | kept | Model stop reason. |  |
| events | `*` | `user.groups` | kept | IdP group membership (gateway sessions). |  |
| events | `*` | `user.id` | kept | Anonymous install id. |  |
| events | `*` | `workflow.run_id` | kept | Workflow run id (wf_...) on workflow-spawned agents. |  |
| events | `*` | `workspace.host_paths` | kept | Desktop workspace dirs. |  |
| events | `api_refusal` | `category` | kept | Refusal category enum. |  |
| events | `api_refusal` | `has_category` | kept | Refusal has-category flag. |  |
| events | `api_refusal` | `has_explanation` | kept | Refusal has-explanation flag. |  |
| events | `api_refusal` | `server_fallback_hop` | kept | Server fallback hop. |  |
| events | `api_request_body` | `body_length` | kept | Raw API request body length. |  |
| events | `api_request_body` | `body_truncated` | kept | Raw API request body truncated flag. |  |
| events | `api_response_body` | `body_length` | kept | Raw API response body length. |  |
| events | `api_response_body` | `body_truncated` | kept | Raw API response body truncated flag. |  |
| events | `api_retries_exhausted` | `total_attempts` | kept | Total attempts. |  |
| events | `api_retries_exhausted` | `total_retry_duration_ms` | kept | Total retry duration. |  |
| events | `assistant_response` | `message.uuid` | kept | Message UUID. |  |
| events | `assistant_response` | `response_length` | kept | Response length in chars. |  |
| events | `auth` | `action` | kept | login/logout. |  |
| events | `auth` | `auth_method` | kept | Auth method. |  |
| events | `auth` | `error_category` | kept | Auth error category (no message). |  |
| events | `compaction` | `post_tokens` | kept | Post-compaction tokens. |  |
| events | `compaction` | `precompute_reuse` | kept | Precompute-reuse outcome. |  |
| events | `compaction` | `pre_tokens` | kept | Pre-compaction tokens. |  |
| events | `feedback_survey` | `appearance_id` | kept | Survey appearance id. |  |
| events | `feedback_survey` | `enabled_via_override` | kept | Survey override flag. |  |
| events | `feedback_survey` | `event_origin` | kept | Where the survey event originated. |  |
| events | `feedback_survey` | `event_origin_server` | kept | Server that originated the survey event. |  |
| events | `feedback_survey` | `event_type` | kept | Survey event type. |  |
| events | `feedback_survey` | `survey_type` | kept | Survey type. |  |
| events | `hook_execution_complete` | `hook_definitions` | kept | Hook definitions (detailed-beta/details gated). |  |
| events | `hook_execution_complete` | `num_blocking` | kept | Blocking hooks. |  |
| events | `hook_execution_complete` | `num_cancelled` | kept | Cancelled hooks. |  |
| events | `hook_execution_complete` | `num_non_blocking_error` | kept | Non-blocking hook errors. |  |
| events | `hook_execution_start` | `hook_definitions` | kept | Hook definitions (detailed-beta/details gated). |  |
| events | `hook_plugin_metrics` | `plugin_id` | kept | Plugin id (name@marketplace). |  |
| events | `hook_registered` | `hook_matcher` | kept | Hook matcher pattern. |  |
| events | `hook_registered` | `hook_type` | kept | Hook type. |  |
| events | `internal_error` | `error_code` | kept | errno (e.g. ENOENT). |  |
| events | `internal_error` | `error_name` | kept | Error class name (no message). |  |
| events | `mcp_server_connection` | `error_code` | kept | Connection error code. |  |
| events | `mcp_server_connection` | `is_plugin` | kept | Plugin-provided MCP flag. |  |
| events | `plugin_installed` | `install.trigger` | kept | Install trigger (cli/ui). |  |
| events | `plugin_installed` | `marketplace.is_official` | kept | Official-marketplace flag. |  |
| events | `plugin_loaded` | `agent_path_count` | kept | Agent path count. |  |
| events | `plugin_loaded` | `command_path_count` | kept | Command path count. |  |
| events | `plugin_loaded` | `enabled_via` | kept | Plugin enablement source. |  |
| events | `plugin_loaded` | `has_hooks` | kept | Plugin declares hooks. |  |
| events | `plugin_loaded` | `has_mcp` | kept | Plugin declares MCP. |  |
| events | `plugin_loaded` | `host_owned_mcp` | kept | Host-owned MCP flag. |  |
| events | `plugin_loaded` | `skill_path_count` | kept | Skill path count. |  |
| events | `skill_activated` | `skill.kind` | kept | Skill kind (workflow). |  |
| events | `subagent_completed` | `agent.source` | kept | Subagent source. |  |
| events | `subagent_completed` | `final_model` | kept | Model the subagent finished on. |  |
| events | `subagent_completed` | `is_built_in` | kept | Built-in subagent flag. |  |
| events | `subagent_completed` | `model_swapped` | kept | Whether the subagent's model changed mid-run. |  |
| events | `tool_decision` | `tool_source` | kept | Where the tool came from (builtin/mcp/sdk_host_builtin_mcp). |  |
| events | `tool_result` | `decision_type` | kept | Decision type. |  |
| events | `tool_result` | `tool_input_size_bytes` | kept | Tool input size. |  |
| events | `tool_result` | `tool_result_size_bytes` | kept | Tool result size. |  |
| events | `user_prompt` | `message.uuid` | kept | Message UUID. |  |
| metrics | `*` | `app.entrypoint` | kept | Launch surface (opt-in). |  |
| metrics | `*` | `context_window_size` | kept | Context window size. |  |
| metrics | `*` | `error.type` | kept | Error type enum. |  |
| metrics | `*` | `fast_mode` | kept | Fast-mode flag. |  |
| metrics | `*` | `gen_ai.operation.name` | kept | GenAI operation. |  |
| metrics | `*` | `gen_ai.provider.name` | kept | GenAI provider. |  |
| metrics | `*` | `gen_ai.request.model` | kept | GenAI request model. |  |
| metrics | `*` | `gen_ai.response.model` | kept | GenAI response model. |  |
| metrics | `*` | `gen_ai.token.type` | kept | GenAI token type. |  |
| metrics | `*` | `gen_ai.tool.name` | kept | GenAI tool. |  |
| metrics | `*` | `host.name` | kept | Hostname. |  |
| metrics | `*` | `identity.source` | kept | Identity source (e.g. gateway-oidc). |  |
| metrics | `*` | `outcome` | kept | Connection outcome. |  |
| metrics | `*` | `output_style` | kept | Output style. |  |
| metrics | `*` | `repo.name` | kept | Repo name. |  |
| metrics | `*` | `repo.owner` | kept | Repo owner. |  |
| metrics | `*` | `session_name` | kept | Session label. |  |
| metrics | `*` | `thinking_enabled` | kept | Thinking-enabled flag. |  |
| metrics | `*` | `transport` | kept | Transport. |  |
| metrics | `*` | `user.groups` | kept | IdP group membership (gateway sessions). |  |
| metrics | `*` | `user.id` | kept | Anonymous install id. |  |
| metrics | `*` | `workspace.host_paths` | kept | Desktop workspace dirs. |  |
| metrics | `claude_code.cost.usage` | `mcp_server.name` | kept | MCP server attribution. |  |
| metrics | `claude_code.cost.usage` | `mcp_tool.name` | kept | MCP tool attribution. |  |
| metrics | `claude_code.token.usage` | `mcp_server.name` | kept | MCP server attribution. |  |
| metrics | `claude_code.token.usage` | `mcp_tool.name` | kept | MCP tool attribution. |  |
| resource | `*` | `claude.deployment_mode` | kept | Deployment mode (e.g. 1p test rows). |  |
| resource | `*` | `company` | kept | Org company. |  |
| resource | `*` | `cost_center` | kept | Org cost center. |  |
| resource | `*` | `department` | kept | Org department (OTEL_RESOURCE_ATTRIBUTES). |  |
| resource | `*` | `host.arch` | kept | Host architecture. |  |
| resource | `*` | `os.version` | kept | OS version. |  |
| resource | `*` | `region` | kept | Org region. |  |
| resource | `*` | `team` | kept | Org team. |  |
| resource | `*` | `wsl.version` | kept | WSL version. |  |
