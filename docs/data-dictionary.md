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
| `raw.metrics` | 1,757,017 |
| `raw.events` | 355,278 |

## `raw.metrics`

### Row counts by signal name

| name | rows | % | first seen | last seen |
|---|---:|---:|---|---|
| `claude_code.token.usage` | 357,708 | 20.4% | 2026-05-24 | 2026-07-29 |
| `claude_code.usage.utilization` | 260,506 | 14.8% | 2026-05-24 | 2026-07-29 |
| `claude_code.usage.reset_in_seconds` | 260,503 | 14.8% | 2026-05-24 | 2026-07-29 |
| `claude_code.context.input_tokens` | 131,353 | 7.5% | 2026-05-24 | 2026-07-16 |
| `claude_code.context.output_tokens` | 131,353 | 7.5% | 2026-05-24 | 2026-07-16 |
| `claude_code.session.duration_ms` | 131,350 | 7.5% | 2026-05-24 | 2026-07-16 |
| `claude_code.session.api_duration_ms` | 131,350 | 7.5% | 2026-05-24 | 2026-07-16 |
| `claude_code.context.used_percentage` | 129,347 | 7.4% | 2026-05-24 | 2026-07-16 |
| `claude_code.cost.usage` | 89,427 | 5.1% | 2026-05-24 | 2026-07-29 |
| `claude_code.active_time.total` | 75,732 | 4.3% | 2026-05-24 | 2026-07-29 |
| `claude_code.lines_of_code.count` | 33,476 | 1.9% | 2026-05-24 | 2026-07-29 |
| `claude_code.code_edit_tool.decision` | 18,383 | 1.0% | 2026-05-24 | 2026-07-29 |
| `claude_code.commit.count` | 3,260 | 0.2% | 2026-05-24 | 2026-07-29 |
| `claude_code.session.count` | 2,847 | 0.2% | 2026-05-24 | 2026-07-29 |
| `claude_code.pull_request.count` | 422 | 0.0% | 2026-05-24 | 2026-07-29 |

### Promoted columns

| column | type | non-null % | unique % | distinct | description | useful for |
|---|---|---:|---:|---:|---|---|
| `ts` | timestamp with time zone | 100.0% | 13.4% | 236,059 | Metric data-point timestamp. | time grain |
| `metric_name` | text | 100.0% | 0.0% | 15 | OTel instrument name. | signal routing |
| `metric_type` | text | 100.0% | 0.0% | 2 | Instrument kind: gauge/sum/histogram. | temporality handling |
| `value` | double precision | 100.0% | 31.4% | 551,699 | Numeric data-point value (delta counters). | all measures |
| `count` | bigint | 0.0% | — | 0 | Pre-aggregated count on histogram instruments. |  |
| `value_kind` | text | 100.0% | 0.0% | 2 | Derived: gauge_last/sum_delta/sum_cumulative/hist_sum. | delta-only staging filter |
| `user_email` | text | 100.0% | 0.0% | 22 | Developer identity (normalized lowercase/trim). | dim_user join |
| `user_account_id` | text | 33.7% | 0.0% | 23 | Anthropic tagged account id. |  |
| `organization_id` | text | 33.1% | 0.0% | 3 | Organization UUID. |  |
| `session_id` | uuid | 100.0% | 0.2% | 3,502 | Claude Code session UUID. | session facts |
| `model` | text | 93.4% | 0.0% | 19 | Model id (usage/cost/LOC metrics). | dim_model |
| `type_label` | text | 26.6% | 0.0% | 8 | Active-time type: user (keyboard) / cli (tools+AI). | active time split |
| `tool_name` | text | 1.0% | 0.0% | 2 | Edit/Write/NotebookEdit. | fact_edit_decision |
| `decision` | text | 1.0% | 0.0% | 2 | accept / reject. | acceptance rate |
| `source` | text | 1.0% | 0.0% | 6 | Decision source: config/hook/user_*. | auto-vs-human split |
| `language` | text | 1.0% | 0.1% | 23 | Detected language. | language mix |
| `usage_window` | text | 29.7% | 0.0% | 3 | Rate-limit window (5h/7d/...). | fact_usage_window |
| `cc_version` | text | 33.1% | 0.0% | 62 | Claude Code version. | install health |
| `query_source` | text | 25.4% | 0.0% | 3 | Request origin: main/subagent/auxiliary. |  |
| `effort` | text | 90.4% | 0.0% | 5 | Reasoning-effort level. |  |
| `speed` | text | 0.0% | — | 0 | fast when fast-mode. |  |
| `agent_name` | text | 5.2% | 0.0% | 16 | Agent attribution (custom collapses). |  |
| `skill_name` | text | 9.7% | 0.1% | 118 | Skill attribution. |  |
| `plugin_name` | text | 3.7% | 0.0% | 9 | Plugin attribution. |  |
| `marketplace_name` | text | 2.8% | 0.0% | 1 | Marketplace attribution. |  |
| `start_type` | text | 0.2% | 0.1% | 3 | fresh/resume/continue/agents_view. | fact_session |
| `scope_name` | text | 100.0% | 0.0% | 2 | OTel instrumentation scope. | wrapper-vs-native split |
| `scope_version` | text | 33.1% | 0.0% | 56 | Instrumentation scope version. |  |
| `process_owner` | text | 0.0% | 100.0% | 1 | OS account the Claude Code process runs under (e.g. a Windows username). | account sharing: a row whose process_owner disagrees with user_email is one person emitting under another person's account |

## `raw.events`

### Row counts by signal name

| name | rows | % | first seen | last seen |
|---|---:|---:|---|---|
| `api_request` | 75,312 | 21.2% | 2026-05-24 | 2026-07-29 |
| `tool_decision` | 69,449 | 19.5% | 2026-05-24 | 2026-07-29 |
| `tool_result` | 57,083 | 16.1% | 2026-07-14 | 2026-07-29 |
| `hook_execution_complete` | 52,607 | 14.8% | 2026-05-24 | 2026-07-29 |
| `hook_execution_start` | 48,458 | 13.6% | 2026-05-24 | 2026-07-29 |
| `assistant_response` | 33,698 | 9.5% | 2026-06-26 | 2026-07-29 |
| `plugin_loaded` | 5,651 | 1.6% | 2026-05-24 | 2026-07-29 |
| `hook_registered` | 4,801 | 1.4% | 2026-05-24 | 2026-07-29 |
| `user_prompt` | 3,664 | 1.0% | 2026-07-14 | 2026-07-29 |
| `subagent_completed` | 1,247 | 0.4% | 2026-05-24 | 2026-07-29 |
| `mcp_server_connection` | 1,206 | 0.3% | 2026-07-14 | 2026-07-29 |
| `skill_activated` | 940 | 0.3% | 2026-06-09 | 2026-07-29 |
| `permission_mode_changed` | 402 | 0.1% | 2026-05-25 | 2026-07-28 |
| `at_mention` | 254 | 0.1% | 2026-07-14 | 2026-07-29 |
| `feedback_survey` | 178 | 0.1% | 2026-05-24 | 2026-07-28 |
| `internal_error` | 123 | 0.0% | 2026-05-25 | 2026-07-29 |
| `api_error` | 85 | 0.0% | 2026-05-25 | 2026-07-28 |
| `compaction` | 57 | 0.0% | 2026-07-16 | 2026-07-28 |
| `plugin_installed` | 26 | 0.0% | 2026-06-04 | 2026-07-28 |
| `api_retries_exhausted` | 21 | 0.0% | 2026-06-05 | 2026-07-27 |
| `auth` | 15 | 0.0% | 2026-07-15 | 2026-07-28 |
| `api_refusal` | 1 | 0.0% | 2026-07-18 | 2026-07-18 |

### Promoted columns

| column | type | non-null % | unique % | distinct | description | useful for |
|---|---|---:|---:|---:|---|---|
| `event_time` | timestamp with time zone | 100.0% | 90.7% | 322,312 | Log-record timestamp. | time grain |
| `event_name` | text | 100.0% | 0.0% | 22 | Event name. | signal routing |
| `severity` | text | 0.0% | — | 0 | Log severity text. |  |
| `body` | text | 100.0% | 0.0% | 22 | OTLP log-record body (event-name string for CC events). |  |
| `user_email` | text | 100.0% | 0.0% | 22 | Developer identity (normalized). | dim_user join |
| `user_account_id` | text | 100.0% | 0.0% | 22 | Anthropic tagged account id. |  |
| `organization_id` | text | 100.0% | 0.0% | 3 | Organization UUID. |  |
| `session_id` | uuid | 100.0% | 0.7% | 2,639 | Claude Code session UUID. | session facts |
| `prompt_id` | uuid | 96.0% | 3.1% | 10,647 | Prompt UUID. | prompt correlation |
| `model` | text | 31.1% | 0.0% | 10 | Model id (api_request/assistant_response). | fact_api_usage |
| `tool_name` | text | 35.6% | 0.0% | 33 | Tool name (tool_decision/tool_result; incl. mcp__*). | bridge_session_mcp |
| `duration_ms` | bigint | 38.0% | 25.6% | 34,563 | Failed request duration. |  |
| `input_tokens` | bigint | 21.2% | 2.6% | 1,977 | Prompt tokens. | fact_api_usage |
| `output_tokens` | bigint | 21.2% | 7.7% | 5,800 | Completion tokens. | fact_api_usage |
| `cache_creation_tokens` | bigint | 21.2% | 15.4% | 11,605 | Cache-write tokens. | fact_api_usage |
| `cache_read_tokens` | bigint | 21.2% | 83.9% | 63,183 | Cache-read tokens. | fact_api_usage |
| `cost_usd` | double precision | 21.2% | 97.3% | 73,304 | Estimated cost. |  |
| `cc_version` | text | 100.0% | 0.0% | 61 | Claude Code version. | install health |
| `event_sequence` | bigint | 100.0% | 3.8% | 13,484 | Per-session event ordinal. |  |
| `request_id` | text | 30.7% | 69.1% | 75,385 | Anthropic API request id. |  |
| `speed` | text | 21.2% | 0.0% | 1 | fast/normal. |  |
| `effort` | text | 20.4% | 0.0% | 5 | Reasoning-effort level. | fact_api_usage |
| `query_source` | text | 30.7% | 0.0% | 22 | Request origin. | fact_api_usage |
| `prompt_length` | bigint | 1.0% | 22.5% | 823 | Prompt length in chars. | non-empty session |
| `command_name` | text | 0.2% | 7.9% | 68 | Slash-command name. |  |
| `command_source` | text | 0.2% | 0.2% | 2 | builtin/custom/mcp. |  |
| `hook_name` | text | 28.4% | 0.1% | 129 | Hook name (hook_execution_*/hook_registered). | bridge_session_hook |
| `hook_event` | text | 29.8% | 0.0% | 10 | Hook trigger event. |  |
| `from_mode` | text | 0.1% | 1.0% | 4 | Permission mode before change. |  |
| `to_mode` | text | 0.1% | 1.0% | 4 | Permission mode after change. |  |
| `trigger` | text | 0.1% | 1.1% | 5 | Compaction trigger (auto/manual). |  |
| `skill_name` | text | 8.1% | 0.5% | 134 | Skill name (skill_activated/api_request). | bridge_session_skill |
| `agent_name` | text | 4.7% | 0.1% | 14 | Agent attribution (api_request). | bridge_session_agent |
| `plugin_name` | text | 5.2% | 0.2% | 41 | Plugin name (plugin_loaded). | bridge_session_plugin |
| `marketplace_name` | text | 4.0% | 0.1% | 15 | Marketplace attribution. |  |
| `mcp_server_name` | text | 1.1% | 0.4% | 16 | MCP server attribution (api_request). | bridge_session_mcp |
| `mcp_tool_name` | text | 1.1% | 0.8% | 29 | MCP tool attribution (api_request). |  |
| `mention_type` | text | 0.1% | 1.2% | 3 | @-mention target type. |  |
| `success_bool` | boolean | 16.2% | 0.0% | 2 | Success flag where reported. |  |
| `tool_use_id` | text | 35.6% | 54.9% | 69,453 | Tool invocation id. |  |
| `decision` | text | 19.5% | 0.0% | 2 | accept / reject (tool_decision). |  |
| `source` | text | 19.5% | 0.0% | 6 | Decision source (tool_decision). |  |
| `scope_name` | text | 100.0% | 0.0% | 1 | Instrumentation scope. |  |
| `scope_version` | text | 100.0% | 0.0% | 55 | Scope version. |  |
| `severity_number` | smallint | 0.0% | — | 0 | Log severity number. |  |
| `log_trace_id` | text | 24.4% | 7.6% | 6,618 | Trace id if present. |  |
| `log_span_id` | text | 24.4% | 28.5% | 24,621 | Span id if present. |  |
| `dropped_attributes_count` | integer | 21.5% | 0.0% | 1 | Dropped-attribute count. | ingest QA |
| `process_owner` | text | 0.0% | 25.0% | 1 | OS account the Claude Code process runs under (e.g. a Windows username). | account sharing: a row whose process_owner disagrees with user_email is one person emitting under another person's account |

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
| events | `*` | `hook_source` | kept | Hook source. |  |
| events | `*` | `identity.source` | kept | Identity source (e.g. gateway-oidc). |  |
| events | `*` | `managed_only` | kept | Managed-only flag. |  |
| events | `*` | `num_hooks` | kept | Hook count for the event. |  |
| events | `*` | `plugin_id_hash` | kept | Plugin id hash. |  |
| events | `*` | `safe_mode` | kept | Safe-mode flag. |  |
| events | `*` | `status_code` | kept | HTTP status code. |  |
| events | `*` | `stop_reason` | kept | Model stop reason. |  |
| events | `*` | `terminal.type` | kept | Terminal app type. |  |
| events | `*` | `user.groups` | kept | IdP group membership (gateway sessions). |  |
| events | `*` | `user.id` | kept | Anonymous install id. |  |
| events | `*` | `workflow.name` | kept | Workflow name (custom unless details). |  |
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
| events | `assistant_response` | `response_length` | kept | Response length in chars. |  |
| events | `auth` | `action` | kept | login/logout. |  |
| events | `auth` | `auth_method` | kept | Auth method. |  |
| events | `auth` | `error_category` | kept | Auth error category (no message). |  |
| events | `compaction` | `post_tokens` | kept | Post-compaction tokens. |  |
| events | `compaction` | `precompute_reuse` | kept | Precompute-reuse outcome. |  |
| events | `compaction` | `pre_tokens` | kept | Pre-compaction tokens. |  |
| events | `feedback_survey` | `appearance_id` | kept | Survey appearance id. |  |
| events | `feedback_survey` | `enabled_via_override` | kept | Survey override flag. |  |
| events | `feedback_survey` | `event_type` | kept | Survey event type. |  |
| events | `feedback_survey` | `survey_type` | kept | Survey type. |  |
| events | `hook_execution_complete` | `hook_definitions` | kept | Hook definitions (detailed-beta/details gated). |  |
| events | `hook_execution_complete` | `num_blocking` | kept | Blocking hooks. |  |
| events | `hook_execution_complete` | `num_cancelled` | kept | Cancelled hooks. |  |
| events | `hook_execution_complete` | `num_non_blocking_error` | kept | Non-blocking hook errors. |  |
| events | `hook_execution_complete` | `num_success` | kept | Successful hooks. |  |
| events | `hook_execution_complete` | `total_duration_ms` | kept | Total hook duration. |  |
| events | `hook_execution_start` | `hook_definitions` | kept | Hook definitions (detailed-beta/details gated). |  |
| events | `hook_plugin_metrics` | `plugin_id` | kept | Plugin id (name@marketplace). |  |
| events | `hook_registered` | `hook_matcher` | kept | Hook matcher pattern. |  |
| events | `hook_registered` | `hook_type` | kept | Hook type. |  |
| events | `internal_error` | `error_code` | kept | errno (e.g. ENOENT). |  |
| events | `internal_error` | `error_name` | kept | Error class name (no message). |  |
| events | `mcp_server_connection` | `error_code` | kept | Connection error code. |  |
| events | `mcp_server_connection` | `is_plugin` | kept | Plugin-provided MCP flag. |  |
| events | `mcp_server_connection` | `server_name` | kept | MCP server name (details). |  |
| events | `mcp_server_connection` | `server_scope` | kept | Server scope. |  |
| events | `mcp_server_connection` | `status` | kept | Connection status. |  |
| events | `mcp_server_connection` | `transport_type` | kept | Transport type. |  |
| events | `plugin_installed` | `install.trigger` | kept | Install trigger (cli/ui). |  |
| events | `plugin_installed` | `marketplace.is_official` | kept | Official-marketplace flag. |  |
| events | `plugin_loaded` | `agent_path_count` | kept | Agent path count. |  |
| events | `plugin_loaded` | `command_path_count` | kept | Command path count. |  |
| events | `plugin_loaded` | `enabled_via` | kept | Plugin enablement source. |  |
| events | `plugin_loaded` | `has_hooks` | kept | Plugin declares hooks. |  |
| events | `plugin_loaded` | `has_mcp` | kept | Plugin declares MCP. |  |
| events | `plugin_loaded` | `host_owned_mcp` | kept | Host-owned MCP flag. |  |
| events | `plugin_loaded` | `plugin.scope` | kept | Plugin scope. |  |
| events | `plugin_loaded` | `plugin.version` | kept | Plugin version. |  |
| events | `plugin_loaded` | `skill_path_count` | kept | Skill path count. |  |
| events | `skill_activated` | `invocation_trigger` | kept | Skill invocation trigger. |  |
| events | `skill_activated` | `skill.kind` | kept | Skill kind (workflow). |  |
| events | `skill_activated` | `skill.source` | kept | Skill source. |  |
| events | `subagent_completed` | `agent.source` | kept | Subagent source. |  |
| events | `subagent_completed` | `agent_type` | kept | Subagent type. |  |
| events | `subagent_completed` | `is_async` | kept | Async subagent flag. |  |
| events | `subagent_completed` | `is_built_in` | kept | Built-in subagent flag. |  |
| events | `subagent_completed` | `total_tokens` | kept | Subagent total tokens. |  |
| events | `subagent_completed` | `total_tool_uses` | kept | Subagent tool-use count. |  |
| events | `tool_result` | `decision_source` | kept | Decision source. |  |
| events | `tool_result` | `decision_type` | kept | Decision type. |  |
| events | `tool_result` | `error_type` | kept | Error category (not the message). |  |
| events | `tool_result` | `mcp_server_scope` | kept | MCP server scope. |  |
| events | `tool_result` | `tool_input_size_bytes` | kept | Tool input size. |  |
| events | `tool_result` | `tool_result_size_bytes` | kept | Tool result size. |  |
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
| metrics | `*` | `terminal.type` | kept | Terminal app type. |  |
| metrics | `*` | `thinking_enabled` | kept | Thinking-enabled flag. |  |
| metrics | `*` | `transport` | kept | Transport. |  |
| metrics | `*` | `user.groups` | kept | IdP group membership (gateway sessions). |  |
| metrics | `*` | `user.id` | kept | Anonymous install id. |  |
| metrics | `*` | `workspace.host_paths` | kept | Desktop workspace dirs. |  |
| metrics | `claude_code.token.usage` | `mcp_server.name` | kept | MCP server attribution. |  |
| metrics | `claude_code.token.usage` | `mcp_tool.name` | kept | MCP tool attribution. |  |
| resource | `*` | `claude.deployment_mode` | kept | Deployment mode (e.g. 1p test rows). |  |
| resource | `*` | `company` | kept | Org company. |  |
| resource | `*` | `cost_center` | kept | Org cost center. |  |
| resource | `*` | `department` | kept | Org department (OTEL_RESOURCE_ATTRIBUTES). |  |
| resource | `*` | `host.arch` | kept | Host architecture. |  |
| resource | `*` | `os.type` | kept | OS type. |  |
| resource | `*` | `os.version` | kept | OS version. |  |
| resource | `*` | `region` | kept | Org region. |  |
| resource | `*` | `service.name` | kept | Service name (claude-code). |  |
| resource | `*` | `team` | kept | Org team. |  |
| resource | `*` | `wsl.version` | kept | WSL version. |  |
