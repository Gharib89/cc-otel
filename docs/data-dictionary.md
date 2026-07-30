# cc-otel — Data Dictionary

> Generated **2026-07-30** by `tools.gen_data_dictionary` against `cc_otel`.
> Row counts are a live snapshot; treat them as representative, not exact.

Descriptions come from `meta.column_registry` (the curated catalogue, #16); profiling
stats are live from `raw.metrics` / `raw.events`. Kept (blob-only) and denied (stripped)
keys have no Postgres column, so they are listed without live stats — use `tools.sweep`
to see what is actually present in the blob reservoir.

**Regenerate:** `uv run python -m tools.gen_data_dictionary` (commit the result).

## Tables profiled

| table | rows |
|---|---:|
| `raw.metrics` | 1,778,039 |
| `raw.events` | 374,660 |

## `raw.metrics`

### Row counts by signal name

| name | rows | % | first seen | last seen |
|---|---:|---:|---|---|
| `claude_code.token.usage` | 369,716 | 20.8% | 2026-05-24 | 2026-07-30 |
| `claude_code.usage.utilization` | 260,880 | 14.7% | 2026-05-24 | 2026-07-30 |
| `claude_code.usage.reset_in_seconds` | 260,877 | 14.7% | 2026-05-24 | 2026-07-30 |
| `claude_code.context.input_tokens` | 131,353 | 7.4% | 2026-05-24 | 2026-07-16 |
| `claude_code.context.output_tokens` | 131,353 | 7.4% | 2026-05-24 | 2026-07-16 |
| `claude_code.session.duration_ms` | 131,350 | 7.4% | 2026-05-24 | 2026-07-16 |
| `claude_code.session.api_duration_ms` | 131,350 | 7.4% | 2026-05-24 | 2026-07-16 |
| `claude_code.context.used_percentage` | 129,347 | 7.3% | 2026-05-24 | 2026-07-16 |
| `claude_code.cost.usage` | 92,429 | 5.2% | 2026-05-24 | 2026-07-30 |
| `claude_code.active_time.total` | 79,033 | 4.4% | 2026-05-24 | 2026-07-30 |
| `claude_code.lines_of_code.count` | 34,684 | 2.0% | 2026-05-24 | 2026-07-30 |
| `claude_code.code_edit_tool.decision` | 19,003 | 1.1% | 2026-05-24 | 2026-07-30 |
| `claude_code.commit.count` | 3,313 | 0.2% | 2026-05-24 | 2026-07-30 |
| `claude_code.session.count` | 2,934 | 0.2% | 2026-05-24 | 2026-07-30 |
| `claude_code.pull_request.count` | 434 | 0.0% | 2026-05-24 | 2026-07-30 |

### Promoted columns

| column | type | non-null % | unique % | distinct | description | useful for |
|---|---|---:|---:|---:|---|---|
| `ts` | timestamp with time zone | 100.0% | 13.5% | 240,309 | Metric data-point timestamp. | time grain |
| `metric_name` | text | 100.0% | 0.0% | 15 | OTel instrument name. | signal routing |
| `metric_type` | text | 100.0% | 0.0% | 2 | Instrument kind: gauge/sum/histogram. | temporality handling |
| `value` | double precision | 100.0% | 31.3% | 557,286 | Numeric data-point value (delta counters). | all measures |
| `count` | bigint | 0.0% | — | 0 | Pre-aggregated count on histogram instruments. |  |
| `value_kind` | text | 100.0% | 0.0% | 2 | Derived: gauge_last/sum_delta/sum_cumulative/hist_sum. | delta-only staging filter |
| `user_email` | text | 100.0% | 0.0% | 22 | Developer identity (normalized lowercase/trim). | dim_user join |
| `user_account_id` | text | 34.4% | 0.0% | 23 | user.account_id: Anthropic tagged account id. / user.account_uuid: Anthropic account UUID. |  |
| `organization_id` | text | 33.8% | 0.0% | 3 | Organization UUID. |  |
| `session_id` | uuid | 100.0% | 0.2% | 3,575 | Claude Code session UUID. | session facts |
| `model` | text | 93.2% | 0.0% | 19 | Model id (usage/cost/LOC metrics). | dim_model |
| `type_label` | text | 27.2% | 0.0% | 8 | claude_code.active_time.total: Active-time type: user (keyboard) / cli (tools+AI). / claude_code.lines_of_code.count: LOC change type: added / removed. / claude_code.token.usage: Token type: input/output/cacheRead/cacheCreation. | claude_code.active_time.total: active time split / claude_code.lines_of_code.count: loc measures / claude_code.token.usage: token breakdown |
| `tool_name` | text | 1.1% | 0.0% | 2 | Edit/Write/NotebookEdit. | fact_edit_decision |
| `decision` | text | 1.1% | 0.0% | 2 | accept / reject. | acceptance rate |
| `source` | text | 1.1% | 0.0% | 6 | Decision source: config/hook/user_*. | auto-vs-human split |
| `language` | text | 1.1% | 0.1% | 23 | Detected language. | language mix |
| `usage_window` | text | 29.3% | 0.0% | 3 | Rate-limit window (5h/7d/...). | fact_usage_window |
| `cc_version` | text | 33.8% | 0.0% | 62 | Claude Code version. | install health |
| `query_source` | text | 26.0% | 0.0% | 3 | Request origin: main/subagent/auxiliary. |  |
| `effort` | text | 90.1% | 0.0% | 5 | Reasoning-effort level. |  |
| `speed` | text | 0.0% | — | 0 | fast when fast-mode. |  |
| `agent_name` | text | 5.3% | 0.0% | 16 | Agent attribution (custom collapses). |  |
| `skill_name` | text | 9.9% | 0.1% | 125 | Skill attribution. |  |
| `plugin_name` | text | 3.8% | 0.0% | 10 | Plugin attribution. |  |
| `marketplace_name` | text | 2.9% | 0.0% | 1 | Marketplace attribution. |  |
| `start_type` | text | 0.2% | 0.1% | 3 | fresh/resume/continue/agents_view. | fact_session |
| `scope_name` | text | 100.0% | 0.0% | 2 | OTel instrumentation scope. | wrapper-vs-native split |
| `scope_version` | text | 33.8% | 0.0% | 56 | Instrumentation scope version. |  |
| `process_owner` | text | 0.0% | 1.0% | 3 | OS account the Claude Code process runs under (e.g. a Windows username). | owner_email_mismatch: a session whose process_owner disagrees with the local-part of an ITWorx user_email. An observation, not an account-sharing control — the CLI never emits process.owner, so 99.6% of records are blind to it (#364) |
| `terminal_type` | text | 0.3% | 0.0% | 2 | Terminal app type (terminal / VS Code / non-interactive). | surface split; non-interactive is adoption, not noise |
| `service_name` | text | 0.3% | 0.0% | 2 | Emitting surface: claude-code / claude-code-desktop / cowork. | desktop adoption; the only key separating the three surfaces |
| `os_type` | text | 0.3% | 0.0% | 2 | OS type; carries the WSL-vs-native-Windows split on its own. | fleet composition figure |

## `raw.events`

### Row counts by signal name

| name | rows | % | first seen | last seen |
|---|---:|---:|---|---|
| `api_request` | 78,776 | 21.0% | 2026-05-24 | 2026-07-30 |
| `tool_decision` | 73,341 | 19.6% | 2026-05-24 | 2026-07-30 |
| `tool_result` | 60,959 | 16.3% | 2026-07-14 | 2026-07-30 |
| `hook_execution_complete` | 55,305 | 14.8% | 2026-05-24 | 2026-07-30 |
| `hook_execution_start` | 51,155 | 13.7% | 2026-05-24 | 2026-07-30 |
| `assistant_response` | 34,969 | 9.3% | 2026-06-26 | 2026-07-30 |
| `plugin_loaded` | 5,974 | 1.6% | 2026-05-24 | 2026-07-30 |
| `hook_registered` | 5,421 | 1.4% | 2026-05-24 | 2026-07-30 |
| `user_prompt` | 3,927 | 1.0% | 2026-07-14 | 2026-07-30 |
| `mcp_server_connection` | 1,313 | 0.4% | 2026-07-14 | 2026-07-30 |
| `subagent_completed` | 1,290 | 0.3% | 2026-05-24 | 2026-07-30 |
| `skill_activated` | 995 | 0.3% | 2026-06-09 | 2026-07-30 |
| `permission_mode_changed` | 418 | 0.1% | 2026-05-25 | 2026-07-30 |
| `at_mention` | 268 | 0.1% | 2026-07-14 | 2026-07-30 |
| `feedback_survey` | 184 | 0.0% | 2026-05-24 | 2026-07-30 |
| `internal_error` | 138 | 0.0% | 2026-05-25 | 2026-07-30 |
| `api_error` | 91 | 0.0% | 2026-05-25 | 2026-07-30 |
| `compaction` | 67 | 0.0% | 2026-07-16 | 2026-07-30 |
| `plugin_installed` | 26 | 0.0% | 2026-06-04 | 2026-07-28 |
| `api_retries_exhausted` | 24 | 0.0% | 2026-06-05 | 2026-07-30 |
| `auth` | 16 | 0.0% | 2026-07-15 | 2026-07-30 |
| `api_refusal` | 3 | 0.0% | 2026-07-18 | 2026-07-29 |

### Promoted columns

| column | type | non-null % | unique % | distinct | description | useful for |
|---|---|---:|---:|---:|---|---|
| `event_time` | timestamp with time zone | 100.0% | 90.8% | 340,159 | Log-record timestamp. | time grain |
| `event_name` | text | 100.0% | 0.0% | 22 | Event name. | signal routing |
| `severity` | text | 0.0% | — | 0 | Log severity text. |  |
| `body` | text | 100.0% | 0.0% | 22 | OTLP log-record body (event-name string for CC events). |  |
| `user_email` | text | 100.0% | 0.0% | 22 | Developer identity (normalized lowercase/trim). | dim_user join |
| `user_account_id` | text | 100.0% | 0.0% | 22 | user.account_id: Anthropic tagged account id. / user.account_uuid: Anthropic account UUID. |  |
| `organization_id` | text | 100.0% | 0.0% | 3 | Organization UUID. |  |
| `session_id` | uuid | 100.0% | 0.7% | 2,712 | Claude Code session UUID. | session facts |
| `prompt_id` | uuid | 95.9% | 3.0% | 10,912 | Prompt UUID. | prompt correlation |
| `model` | text | 30.7% | 0.0% | 10 | Model id (api_request/assistant_response). | fact_api_usage |
| `tool_name` | text | 35.8% | 0.0% | 33 | Tool name (tool_decision/tool_result; incl. mcp__*). | bridge_session_mcp |
| `duration_ms` | bigint | 38.0% | 24.8% | 35,320 | api_error: Failed request duration. / api_request: API request duration. / compaction: Compaction duration. / mcp_server_connection: MCP server connection duration. / subagent_completed: Subagent duration. / tool_result: Tool execution duration. |  |
| `input_tokens` | bigint | 21.0% | 2.6% | 2,013 | Prompt tokens. | fact_api_usage |
| `output_tokens` | bigint | 21.0% | 7.5% | 5,896 | Completion tokens. | fact_api_usage |
| `cache_creation_tokens` | bigint | 21.0% | 15.1% | 11,897 | Cache-write tokens. | fact_api_usage |
| `cache_read_tokens` | bigint | 21.0% | 83.4% | 65,686 | Cache-read tokens. | fact_api_usage |
| `cost_usd` | double precision | 21.0% | 97.1% | 76,519 | Estimated cost. |  |
| `cc_version` | text | 100.0% | 0.0% | 61 | Claude Code version. | install health |
| `event_sequence` | bigint | 100.0% | 3.6% | 13,484 | Per-session event ordinal. |  |
| `request_id` | text | 30.4% | 69.3% | 78,853 | Anthropic API request id. |  |
| `speed` | text | 21.1% | 0.0% | 1 | fast/normal. |  |
| `effort` | text | 20.2% | 0.0% | 5 | Reasoning-effort level. | fact_api_usage |
| `query_source` | text | 30.4% | 0.0% | 22 | Request origin. | fact_api_usage |
| `prompt_length` | bigint | 1.0% | 21.9% | 859 | Prompt length in chars. | non-empty session |
| `command_name` | text | 0.2% | 7.9% | 73 | Slash-command name. |  |
| `command_source` | text | 0.2% | 0.2% | 2 | builtin/custom/mcp. |  |
| `hook_name` | text | 28.4% | 0.1% | 130 | Hook name (hook_execution_*/hook_registered). | bridge_session_hook |
| `hook_event` | text | 29.9% | 0.0% | 10 | Hook trigger event. |  |
| `from_mode` | text | 0.1% | 1.0% | 4 | Permission mode before change. |  |
| `to_mode` | text | 0.1% | 1.0% | 4 | Permission mode after change. |  |
| `trigger` | text | 0.1% | 1.1% | 5 | compaction: Compaction trigger (auto/manual). / permission_mode_changed: Mode-change trigger. |  |
| `skill_name` | text | 8.1% | 0.5% | 142 | Skill name (skill_activated/api_request). | bridge_session_skill |
| `agent_name` | text | 4.6% | 0.1% | 14 | Agent attribution (api_request). | bridge_session_agent |
| `plugin_name` | text | 5.3% | 0.2% | 41 | Plugin name (plugin_loaded). | bridge_session_plugin |
| `marketplace_name` | text | 4.0% | 0.1% | 15 | Marketplace attribution. |  |
| `mcp_server_name` | text | 1.0% | 0.4% | 16 | MCP server attribution (api_request). | bridge_session_mcp |
| `mcp_tool_name` | text | 1.0% | 0.8% | 29 | MCP tool attribution (api_request). |  |
| `mention_type` | text | 0.1% | 1.1% | 3 | @-mention target type. |  |
| `success_bool` | boolean | 16.4% | 0.0% | 2 | Success flag where reported. |  |
| `tool_use_id` | text | 35.8% | 54.6% | 73,345 | Tool invocation id. |  |
| `decision` | text | 19.6% | 0.0% | 2 | accept / reject (tool_decision). |  |
| `source` | text | 19.6% | 0.0% | 6 | Decision source (tool_decision). |  |
| `scope_name` | text | 100.0% | 0.0% | 1 | Instrumentation scope. |  |
| `scope_version` | text | 100.0% | 0.0% | 55 | Scope version. |  |
| `severity_number` | smallint | 0.0% | — | 0 | Log severity number. |  |
| `log_trace_id` | text | 23.1% | 7.6% | 6,618 | Trace id if present. |  |
| `log_span_id` | text | 23.1% | 28.5% | 24,621 | Span id if present. |  |
| `dropped_attributes_count` | integer | 20.4% | 0.0% | 1 | Dropped-attribute count. | ingest QA |
| `process_owner` | text | 0.1% | 1.0% | 3 | OS account the Claude Code process runs under (e.g. a Windows username). | owner_email_mismatch: a session whose process_owner disagrees with the local-part of an ITWorx user_email. An observation, not an account-sharing control — the CLI never emits process.owner, so 99.6% of records are blind to it (#364) |
| `service_name` | text | 1.4% | 0.0% | 2 | Emitting surface: claude-code / claude-code-desktop / cowork. | desktop adoption; the only key separating the three surfaces |
| `os_type` | text | 1.4% | 0.0% | 2 | OS type; carries the WSL-vs-native-Windows split on its own. | fleet composition figure |
| `terminal_type` | text | 1.3% | 0.0% | 2 | Terminal app type (terminal / VS Code / non-interactive). | surface split; non-interactive is adoption, not noise |
| `workflow_name` | text | 0.0% | — | 0 | Workflow name on workflow-spawned agents. | dynamic-workflow adoption (a figure, not a slicer) |
| `mcp_connection_server_name` | text | 0.0% | 34.6% | 9 | MCP server display name on the connection event. | installed-and-idle MCP servers: ~25 connect, 8 are ever paid for |
| `mcp_connection_status` | text | 0.0% | 11.5% | 3 | MCP connection status (connected/disconnected/failed). | separates idle from broken -- retire vs fix |
| `mcp_transport_type` | text | 0.0% | 11.5% | 3 | MCP transport (claudeai-proxy/stdio/ws-ide). | hosted vs local; what IS must allow through the network |
| `mcp_connection_server_scope` | text | 0.0% | 15.4% | 4 | MCP server scope on the connection event (claudeai/dynamic/project/local/user). |  |
| `mcp_server_scope` | text | 0.0% | 100.0% | 1 | MCP server scope on the tool-result event. |  |
| `agent_type` | text | 0.0% | 22.2% | 2 | Subagent type on the completion event. | subagent run counts (query_source counts requests, not runs) |
| `subagent_is_async` | boolean | 0.0% | 22.2% | 2 | Background-agent flag. | nothing else records background-agent use |
| `subagent_tool_uses` | bigint | 0.0% | 88.9% | 8 | Tool calls made by the subagent. | irreducible: tool_decision.query_source is NULL on all rows |
| `subagent_total_tokens` | bigint | 0.0% | 100.0% | 9 | Tokens consumed by the subagent run. | query_source='agent:custom' collapses every custom agent into one bucket |
| `plugin_scope` | text | 0.0% | 3.0% | 2 | Plugin scope (official/user-local). | per-seat fact: the same plugin loads official on some seats, user-local on others |
| `plugin_version` | text | 0.0% | 16.1% | 10 | Plugin version. | staleness spread across seats |
| `skill_invocation_trigger` | text | 0.0% | 21.4% | 3 | Skill invocation trigger (user-slash/claude-proactive/nested-skill). | human pull vs model push; a slicer, never a filter baked into a measure |
| `skill_source` | text | 0.0% | 21.4% | 3 | Skill source (userSettings/projectSettings/plugin/bundled/builtin). | do skills spread through the team or stay personal |
| `decision_source` | text | 0.2% | 0.4% | 3 | Who authorised the tool call (config/hook/user_temporary/...). | permission friction: user_temporary on 12 of 13 seats |
| `error_type` | text | 0.0% | 10.5% | 2 | Tool failure category (not the message). | the only route to a failure taxonomy -- free-text `error` is denied |
| `status_code` | smallint | 0.0% | 16.7% | 1 | HTTP status code. | decomposes fact_api_error_rate: 429 (tier) vs 529 (overload) vs 500 (fault) |
| `num_hooks` | smallint | 0.4% | 0.3% | 4 | Hooks matched for the event. | how much hook machinery the fleet runs |
| `num_success` | smallint | 0.2% | 0.7% | 5 | Hooks that succeeded. | with num_hooks, states the failure count exactly |
| `hook_source` | text | 0.4% | 0.3% | 4 | Where the hook came from (settings/pluginHook/...). | attributes hook load to plugins, which the plugin columns cannot |
| `total_duration_ms` | bigint | 0.2% | 72.8% | 498 | Total time across the hooks run for one event. | hook overhead: bridge_session_hook has executions and no time |

## Kept & denied attributes (not in Postgres)

`kept` = blob reservoir only; `denied` = stripped by the sink wherever seen.

**basis** is why a key is `kept` rather than promoted (#366): `nature` (identity or
unbounded cardinality), `constant`, `collinear(partner)`, `thin`, or `redundant`.
`nature` and `redundant` carry no machine predicate; `uv run python -m tools.basis_drift`
re-checks the other three against a recent window.

| signal | signal name | attr path | status | basis | description | useful for |
|---|---|---|---|---|---|---|
| events | `*` | `bash_command` | denied | — | Bash command. |  |
| events | `*` | `error` | denied | — | Error message. |  |
| events | `*` | `file_path` | denied | — | File path. |  |
| events | `*` | `full_command` | denied | — | Full command line. |  |
| events | `api_request_body` | `body` | denied | — | Raw API request body. |  |
| events | `api_request_body` | `body_ref` | denied | — | Raw API request body file ref. |  |
| events | `api_response_body` | `body` | denied | — | Raw API response body. |  |
| events | `api_response_body` | `body_ref` | denied | — | Raw API response body file ref. |  |
| events | `assistant_response` | `response` | denied | — | Assistant response text. |  |
| events | `feedback_survey` | `response` | denied | — | Survey free-text response. |  |
| events | `tool_decision` | `tool_parameters` | denied | — | Tool args JSON (details-gated). |  |
| events | `tool_result` | `tool_input` | denied | — | Tool args JSON (details-gated). |  |
| events | `tool_result` | `tool_parameters` | denied | — | Tool args JSON (details-gated). |  |
| events | `user_prompt` | `prompt` | denied | — | Prompt text. |  |
| events | `*` | `attempt` | kept | nature | API attempt number. |  |
| events | `*` | `client_request_id` | kept | nature | Client request id. |  |
| events | `*` | `cost_usd_micros` | kept | nature | Cost in micros. |  |
| events | `*` | `event.timestamp` | kept | nature | ISO event timestamp. |  |
| events | `*` | `identity.source` | kept | nature | Identity source (e.g. gateway-oidc). |  |
| events | `*` | `managed_only` | kept | constant | Managed-only flag. |  |
| events | `*` | `plugin_id_hash` | kept | nature | Plugin id hash. |  |
| events | `*` | `safe_mode` | kept | constant | Safe-mode flag. |  |
| events | `*` | `stop_reason` | kept | nature | Model stop reason. |  |
| events | `*` | `user.groups` | kept | nature | IdP group membership (gateway sessions). |  |
| events | `*` | `user.id` | kept | nature | Anonymous install id. |  |
| events | `*` | `workflow.run_id` | kept | nature | Workflow run id (wf_...) on workflow-spawned agents. |  |
| events | `*` | `workspace.host_paths` | kept | thin | Desktop workspace dirs. |  |
| events | `api_refusal` | `category` | kept | nature | Refusal category enum. |  |
| events | `api_refusal` | `has_category` | kept | nature | Refusal has-category flag. |  |
| events | `api_refusal` | `has_explanation` | kept | nature | Refusal has-explanation flag. |  |
| events | `api_refusal` | `server_fallback_hop` | kept | constant | Server fallback hop. |  |
| events | `api_request_body` | `body_length` | kept | nature | Raw API request body length. |  |
| events | `api_request_body` | `body_truncated` | kept | nature | Raw API request body truncated flag. |  |
| events | `api_response_body` | `body_length` | kept | nature | Raw API response body length. |  |
| events | `api_response_body` | `body_truncated` | kept | nature | Raw API response body truncated flag. |  |
| events | `api_retries_exhausted` | `total_attempts` | kept | constant | Total attempts. |  |
| events | `api_retries_exhausted` | `total_retry_duration_ms` | kept | nature | Total retry duration. |  |
| events | `assistant_response` | `message.uuid` | kept | redundant | Message UUID. |  |
| events | `assistant_response` | `response_length` | kept | nature | Response length in chars. |  |
| events | `auth` | `action` | kept | constant | login/logout. |  |
| events | `auth` | `auth_method` | kept | constant | Auth method. |  |
| events | `auth` | `error_category` | kept | nature | Auth error category (no message). |  |
| events | `compaction` | `post_tokens` | kept | nature | Post-compaction tokens. |  |
| events | `compaction` | `precompute_reuse` | kept | nature | Precompute-reuse outcome. |  |
| events | `compaction` | `pre_tokens` | kept | nature | Pre-compaction tokens. |  |
| events | `feedback_survey` | `appearance_id` | kept | nature | Survey appearance id. |  |
| events | `feedback_survey` | `enabled_via_override` | kept | constant | Survey override flag. |  |
| events | `feedback_survey` | `event_origin` | kept | constant | Where the survey event originated. |  |
| events | `feedback_survey` | `event_origin_server` | kept | constant | Server that originated the survey event. |  |
| events | `feedback_survey` | `event_type` | kept | nature | Survey event type. |  |
| events | `feedback_survey` | `survey_type` | kept | constant | Survey type. |  |
| events | `hook_execution_complete` | `hook_definitions` | kept | nature | Hook definitions (detailed-beta/details gated). |  |
| events | `hook_execution_complete` | `num_blocking` | kept | nature | Blocking hooks. |  |
| events | `hook_execution_complete` | `num_cancelled` | kept | nature | Cancelled hooks. |  |
| events | `hook_execution_complete` | `num_non_blocking_error` | kept | nature | Non-blocking hook errors. |  |
| events | `hook_execution_start` | `hook_definitions` | kept | nature | Hook definitions (detailed-beta/details gated). |  |
| events | `hook_plugin_metrics` | `plugin_id` | kept | nature | Plugin id (name@marketplace). |  |
| events | `hook_registered` | `hook_matcher` | kept | nature | Hook matcher pattern. |  |
| events | `hook_registered` | `hook_type` | kept | constant | Hook type. |  |
| events | `internal_error` | `error_code` | kept | nature | errno (e.g. ENOENT). |  |
| events | `internal_error` | `error_name` | kept | nature | Error class name (no message). |  |
| events | `mcp_server_connection` | `error_code` | kept | nature | Connection error code. |  |
| events | `mcp_server_connection` | `is_plugin` | kept | nature | Plugin-provided MCP flag. |  |
| events | `plugin_installed` | `install.trigger` | kept | nature | Install trigger (cli/ui). |  |
| events | `plugin_installed` | `marketplace.is_official` | kept | nature | Official-marketplace flag. |  |
| events | `plugin_loaded` | `agent_path_count` | kept | nature | Agent path count. |  |
| events | `plugin_loaded` | `command_path_count` | kept | nature | Command path count. |  |
| events | `plugin_loaded` | `enabled_via` | kept | constant | Plugin enablement source. |  |
| events | `plugin_loaded` | `has_hooks` | kept | nature | Plugin declares hooks. |  |
| events | `plugin_loaded` | `has_mcp` | kept | nature | Plugin declares MCP. |  |
| events | `plugin_loaded` | `host_owned_mcp` | kept | constant | Host-owned MCP flag. |  |
| events | `plugin_loaded` | `skill_path_count` | kept | nature | Skill path count. |  |
| events | `skill_activated` | `skill.kind` | kept | constant | Skill kind (workflow). |  |
| events | `subagent_completed` | `agent.source` | kept | nature | Subagent source. |  |
| events | `subagent_completed` | `final_model` | kept | redundant | Model the subagent finished on. |  |
| events | `subagent_completed` | `is_built_in` | kept | nature | Built-in subagent flag. |  |
| events | `subagent_completed` | `model_swapped` | kept | constant | Whether the subagent's model changed mid-run. |  |
| events | `tool_decision` | `tool_source` | kept | redundant | Where the tool came from (builtin/mcp/sdk_host_builtin_mcp). |  |
| events | `tool_result` | `decision_type` | kept | constant | Decision type. |  |
| events | `tool_result` | `tool_input_size_bytes` | kept | nature | Tool input size. |  |
| events | `tool_result` | `tool_result_size_bytes` | kept | nature | Tool result size. |  |
| events | `user_prompt` | `message.uuid` | kept | redundant | Message UUID. |  |
| metrics | `*` | `app.entrypoint` | kept | nature | Launch surface (opt-in). |  |
| metrics | `*` | `context_window_size` | kept | nature | Context window size. |  |
| metrics | `*` | `error.type` | kept | nature | Error type enum. |  |
| metrics | `*` | `fast_mode` | kept | nature | Fast-mode flag. |  |
| metrics | `*` | `gen_ai.operation.name` | kept | nature | GenAI operation. |  |
| metrics | `*` | `gen_ai.provider.name` | kept | nature | GenAI provider. |  |
| metrics | `*` | `gen_ai.request.model` | kept | nature | GenAI request model. |  |
| metrics | `*` | `gen_ai.response.model` | kept | nature | GenAI response model. |  |
| metrics | `*` | `gen_ai.token.type` | kept | nature | GenAI token type. |  |
| metrics | `*` | `gen_ai.tool.name` | kept | nature | GenAI tool. |  |
| metrics | `*` | `host.name` | kept | nature | Hostname. |  |
| metrics | `*` | `identity.source` | kept | nature | Identity source (e.g. gateway-oidc). |  |
| metrics | `*` | `outcome` | kept | nature | Connection outcome. |  |
| metrics | `*` | `output_style` | kept | nature | Output style. |  |
| metrics | `*` | `repo.name` | kept | nature | Repo name. |  |
| metrics | `*` | `repo.owner` | kept | nature | Repo owner. |  |
| metrics | `*` | `session_name` | kept | nature | Session label. |  |
| metrics | `*` | `thinking_enabled` | kept | nature | Thinking-enabled flag. |  |
| metrics | `*` | `transport` | kept | nature | Transport. |  |
| metrics | `*` | `user.groups` | kept | nature | IdP group membership (gateway sessions). |  |
| metrics | `*` | `user.id` | kept | nature | Anonymous install id. |  |
| metrics | `*` | `workspace.host_paths` | kept | thin | Desktop workspace dirs. |  |
| metrics | `claude_code.cost.usage` | `mcp_server.name` | kept | redundant | MCP server attribution. |  |
| metrics | `claude_code.cost.usage` | `mcp_tool.name` | kept | redundant | MCP tool attribution. |  |
| metrics | `claude_code.token.usage` | `mcp_server.name` | kept | nature | MCP server attribution. |  |
| metrics | `claude_code.token.usage` | `mcp_tool.name` | kept | nature | MCP tool attribution. |  |
| resource | `*` | `claude.deployment_mode` | kept | constant | Deployment mode (e.g. 1p test rows). |  |
| resource | `*` | `company` | kept | nature | Org company. |  |
| resource | `*` | `cost_center` | kept | nature | Org cost center. |  |
| resource | `*` | `department` | kept | nature | Org department (OTEL_RESOURCE_ATTRIBUTES). |  |
| resource | `*` | `host.arch` | kept | constant | Host architecture. |  |
| resource | `*` | `os.version` | kept | collinear(os.type) | OS version. |  |
| resource | `*` | `region` | kept | nature | Org region. |  |
| resource | `*` | `team` | kept | nature | Org team. |  |
| resource | `*` | `wsl.version` | kept | collinear(os.type) | WSL version. |  |
