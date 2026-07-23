# cc-otel — Data Dictionary

> Generated **2026-07-18** by `tools.gen_data_dictionary` against `cc_otel`.
> Row counts are a live snapshot; treat them as representative, not exact.

Descriptions come from `meta.column_registry` (the curated catalogue, #16); profiling
stats are live from `raw.metrics` / `raw.events`. Kept (blob-only) and denied (stripped)
keys have no Postgres column, so they are listed without live stats — use `tools.sweep`
to see what is actually present in the blob reservoir.

**Regenerate:** `uv run python -m tools.gen_data_dictionary` (commit the result).

## Tables profiled

| table | rows |
|---|---:|
| `raw.metrics` | 16,227 |
| `raw.events` | 41,888 |

## `raw.metrics`

### Row counts by signal name

| name | rows | % | first seen | last seen |
|---|---:|---:|---|---|
| `claude_code.token.usage` | 10,016 | 61.7% | 2026-07-14 | 2026-07-18 |
| `claude_code.cost.usage` | 2,504 | 15.4% | 2026-07-14 | 2026-07-18 |
| `claude_code.active_time.total` | 1,709 | 10.5% | 2026-07-14 | 2026-07-18 |
| `claude_code.lines_of_code.count` | 838 | 5.2% | 2026-07-16 | 2026-07-18 |
| `claude_code.code_edit_tool.decision` | 429 | 2.6% | 2026-07-16 | 2026-07-18 |
| `claude_code.usage.utilization` | 282 | 1.7% | 2026-07-16 | 2026-07-18 |
| `claude_code.usage.reset_in_seconds` | 282 | 1.7% | 2026-07-16 | 2026-07-18 |
| `claude_code.commit.count` | 91 | 0.6% | 2026-07-16 | 2026-07-18 |
| `claude_code.session.count` | 74 | 0.5% | 2026-07-14 | 2026-07-18 |
| `claude_code.pull_request.count` | 2 | 0.0% | 2026-07-18 | 2026-07-18 |

### Promoted columns

| column | type | non-null % | unique % | distinct | description | useful for |
|---|---|---:|---:|---:|---|---|
| `ts` | timestamp with time zone | 100.0% | 21.2% | 3,437 | Metric data-point timestamp. | time grain |
| `metric_name` | text | 100.0% | 0.1% | 10 | OTel instrument name. | signal routing |
| `metric_type` | text | 100.0% | 0.0% | 2 | Instrument kind: gauge/sum/histogram. | temporality handling |
| `value` | double precision | 100.0% | 57.1% | 9,270 | Numeric data-point value (delta counters). | all measures |
| `count` | bigint | 0.0% | — | 0 | Pre-aggregated count on histogram instruments. |  |
| `value_kind` | text | 100.0% | 0.0% | 2 | Derived: gauge_last/sum_delta/sum_cumulative/hist_sum. | delta-only staging filter |
| `user_email` | text | 100.0% | 0.0% | 3 | Developer identity (normalized lowercase/trim). | dim_user join |
| `user_account_id` | text | 100.0% | 0.0% | 3 | Anthropic tagged account id. |  |
| `organization_id` | text | 96.5% | 0.0% | 2 | Organization UUID. |  |
| `session_id` | uuid | 100.0% | 0.5% | 86 | Claude Code session UUID. | session facts |
| `model` | text | 82.3% | 0.0% | 6 | Model id (usage/cost/LOC metrics). | dim_model |
| `type_label` | text | 77.4% | 0.1% | 8 | Active-time type: user (keyboard) / cli (tools+AI). | active time split |
| `tool_name` | text | 2.6% | 0.5% | 2 | Edit/Write/NotebookEdit. | fact_edit_decision |
| `decision` | text | 2.6% | 0.2% | 1 | accept / reject. | acceptance rate |
| `source` | text | 2.6% | 0.5% | 2 | Decision source: config/hook/user_*. | auto-vs-human split |
| `language` | text | 2.6% | 2.1% | 9 | Detected language. | language mix |
| `usage_window` | text | 3.5% | 0.4% | 2 | Rate-limit window (5h/7d/...). | fact_usage_window |
| `cc_version` | text | 96.5% | 0.1% | 8 | Claude Code version. | install health |
| `query_source` | text | 77.2% | 0.0% | 3 | Request origin: main/subagent/auxiliary. |  |
| `effort` | text | 74.0% | 0.0% | 2 | Reasoning-effort level. |  |
| `speed` | text | 0.0% | — | 0 | fast when fast-mode. |  |
| `agent_name` | text | 29.2% | 0.1% | 3 | Agent attribution (custom collapses). |  |
| `skill_name` | text | 20.7% | 0.5% | 18 | Skill attribution. |  |
| `plugin_name` | text | 7.8% | 0.1% | 1 | Plugin attribution. |  |
| `marketplace_name` | text | 7.8% | 0.1% | 1 | Marketplace attribution. |  |
| `start_type` | text | 0.5% | 4.1% | 3 | fresh/resume/continue/agents_view. | fact_session |
| `scope_name` | text | 100.0% | 0.0% | 2 | OTel instrumentation scope. | wrapper-vs-native split |
| `scope_version` | text | 96.5% | 0.0% | 4 | Instrumentation scope version. |  |

## `raw.events`

### Row counts by signal name

| name | rows | % | first seen | last seen |
|---|---:|---:|---|---|
| `tool_decision` | 9,175 | 21.9% | 2026-07-14 | 2026-07-18 |
| `tool_result` | 9,128 | 21.8% | 2026-07-14 | 2026-07-18 |
| `api_request` | 8,663 | 20.7% | 2026-07-14 | 2026-07-18 |
| `assistant_response` | 5,454 | 13.0% | 2026-07-14 | 2026-07-18 |
| `hook_execution_start` | 3,572 | 8.5% | 2026-07-14 | 2026-07-18 |
| `hook_execution_complete` | 3,572 | 8.5% | 2026-07-14 | 2026-07-18 |
| `user_prompt` | 588 | 1.4% | 2026-07-14 | 2026-07-18 |
| `plugin_loaded` | 523 | 1.2% | 2026-07-14 | 2026-07-18 |
| `hook_registered` | 399 | 1.0% | 2026-07-14 | 2026-07-18 |
| `subagent_completed` | 326 | 0.8% | 2026-07-14 | 2026-07-18 |
| `mcp_server_connection` | 235 | 0.6% | 2026-07-14 | 2026-07-18 |
| `skill_activated` | 153 | 0.4% | 2026-07-14 | 2026-07-18 |
| `at_mention` | 39 | 0.1% | 2026-07-14 | 2026-07-18 |
| `permission_mode_changed` | 20 | 0.0% | 2026-07-14 | 2026-07-15 |
| `api_error` | 12 | 0.0% | 2026-07-14 | 2026-07-18 |
| `internal_error` | 11 | 0.0% | 2026-07-16 | 2026-07-18 |
| `feedback_survey` | 10 | 0.0% | 2026-07-14 | 2026-07-18 |
| `auth` | 5 | 0.0% | 2026-07-15 | 2026-07-16 |
| `api_retries_exhausted` | 2 | 0.0% | 2026-07-17 | 2026-07-17 |
| `compaction` | 1 | 0.0% | 2026-07-16 | 2026-07-16 |

### Promoted columns

| column | type | non-null % | unique % | distinct | description | useful for |
|---|---|---:|---:|---:|---|---|
| `event_time` | timestamp with time zone | 100.0% | 88.4% | 37,010 | Log-record timestamp. | time grain |
| `event_name` | text | 100.0% | 0.0% | 20 | Event name. | signal routing |
| `severity` | text | 0.0% | — | 0 | Log severity text. |  |
| `body` | text | 100.0% | 0.0% | 20 | OTLP log-record body (event-name string for CC events). |  |
| `user_email` | text | 100.0% | 0.0% | 5 | Developer identity (normalized). | dim_user join |
| `user_account_id` | text | 100.0% | 0.0% | 5 | Anthropic tagged account id. |  |
| `organization_id` | text | 100.0% | 0.0% | 2 | Organization UUID. |  |
| `session_id` | uuid | 100.0% | 0.4% | 180 | Claude Code session UUID. | session facts |
| `prompt_id` | uuid | 96.6% | 1.5% | 589 | Prompt UUID. | prompt correlation |
| `model` | text | 34.5% | 0.0% | 6 | Model id (api_request/assistant_response). | fact_api_usage |
| `tool_name` | text | 43.7% | 0.1% | 27 | Tool name (tool_decision/tool_result; incl. mcp__*). | bridge_session_mcp |
| `duration_ms` | bigint | 43.8% | 55.4% | 10,166 | Failed request duration. |  |
| `input_tokens` | bigint | 20.7% | 3.2% | 281 | Prompt tokens. | fact_api_usage |
| `output_tokens` | bigint | 20.7% | 26.0% | 2,250 | Completion tokens. | fact_api_usage |
| `cache_creation_tokens` | bigint | 20.7% | 46.0% | 3,984 | Cache-write tokens. | fact_api_usage |
| `cache_read_tokens` | bigint | 20.7% | 89.4% | 7,743 | Cache-read tokens. | fact_api_usage |
| `cost_usd` | double precision | 20.7% | 99.4% | 8,610 | API-equivalent value consumed (flat per-seat, not spend). | fact_api_usage |
| `cc_version` | text | 100.0% | 0.0% | 10 | Claude Code version. | install health |
| `event_sequence` | bigint | 100.0% | 7.4% | 3,091 | Per-session event ordinal. |  |
| `request_id` | text | 33.7% | 61.4% | 8,675 | Anthropic API request id. |  |
| `speed` | text | 20.7% | 0.0% | 1 | fast/normal. |  |
| `effort` | text | 20.0% | 0.0% | 2 | Reasoning-effort level. | fact_api_usage |
| `query_source` | text | 33.7% | 0.1% | 13 | Request origin. | fact_api_usage |
| `prompt_length` | bigint | 1.4% | 40.6% | 239 | Prompt length in chars. | non-empty session |
| `command_name` | text | 0.3% | 20.0% | 24 | Slash-command name. |  |
| `command_source` | text | 0.3% | 1.7% | 2 | builtin/custom/mcp. |  |
| `hook_name` | text | 17.1% | 0.2% | 12 | Hook name (hook_execution_*/hook_registered). | bridge_session_hook |
| `hook_event` | text | 18.0% | 0.1% | 6 | Hook trigger event. |  |
| `from_mode` | text | 0.0% | 20.0% | 4 | Permission mode before change. |  |
| `to_mode` | text | 0.0% | 20.0% | 4 | Permission mode after change. |  |
| `trigger` | text | 0.1% | 14.3% | 3 | Mode-change trigger. |  |
| `skill_name` | text | 7.9% | 0.8% | 27 | Skill name (skill_activated/api_request). | bridge_session_skill |
| `agent_name` | text | 8.5% | 0.1% | 3 | Agent attribution (api_request). | bridge_session_agent |
| `plugin_name` | text | 6.5% | 0.5% | 13 | Plugin name (plugin_loaded). | bridge_session_plugin |
| `marketplace_name` | text | 5.8% | 0.2% | 5 | Marketplace attribution. |  |
| `mcp_server_name` | text | 0.5% | 1.9% | 4 | MCP server attribution (api_request). | bridge_session_mcp |
| `mcp_tool_name` | text | 0.5% | 1.9% | 4 | MCP tool attribution (api_request). |  |
| `mention_type` | text | 0.1% | 5.1% | 2 | @-mention target type. |  |
| `success_bool` | boolean | 21.9% | 0.0% | 2 | Success flag where reported. |  |
| `tool_use_id` | text | 43.7% | 50.1% | 9,175 | Tool invocation id. |  |
| `decision` | text | 21.9% | 0.0% | 2 | accept / reject (tool_decision). |  |
| `source` | text | 21.9% | 0.0% | 4 | Decision source (tool_decision). |  |
| `scope_name` | text | 100.0% | 0.0% | 1 | Instrumentation scope. |  |
| `scope_version` | text | 100.0% | 0.0% | 6 | Scope version. |  |
| `severity_number` | smallint | 0.0% | — | 0 | Log severity number. |  |
| `log_trace_id` | text | 44.5% | 0.8% | 155 | Trace id if present. |  |
| `log_span_id` | text | 44.5% | 24.3% | 4,534 | Span id if present. |  |
| `dropped_attributes_count` | integer | 0.0% | — | 0 | Dropped-attribute count. | ingest QA |

## Kept & denied attributes (not in Postgres)

`kept` = blob reservoir only; `denied` = stripped by the sink wherever seen.

| signal | signal name | attr path | status | description | useful for |
|---|---|---|---|---|---|
| events | `*` | `bash_command` | denied | Bash command. |  |
| events | `*` | `error` | denied | Error message. |  |
| events | `*` | `file_path` | denied | File path. |  |
| events | `*` | `full_command` | denied | Full command line. |  |
| events | `*` | `tool_parameters.bash_command` | denied | Bash command inside tool_parameters. |  |
| events | `*` | `tool_parameters.file_path` | denied | File path inside tool_parameters. |  |
| events | `*` | `tool_parameters.full_command` | denied | Full command inside tool_parameters. |  |
| events | `api_request_body` | `body` | denied | Raw API request body. |  |
| events | `api_request_body` | `body_ref` | denied | Raw API request body file ref. |  |
| events | `api_response_body` | `body` | denied | Raw API response body. |  |
| events | `api_response_body` | `body_ref` | denied | Raw API response body file ref. |  |
| events | `assistant_response` | `response` | denied | Assistant response text. |  |
| events | `feedback_survey` | `response` | denied | Survey free-text response. |  |
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
| events | `compaction` | `trigger` | kept | Compaction trigger (auto/manual). |  |
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
| events | `tool_result` | `tool_input` | kept | Tool args JSON (details-gated). |  |
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
