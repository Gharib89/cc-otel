# Claude Code OpenTelemetry Signals Catalog

**Date:** 2026-07-12

**Research question:** Full catalog of OpenTelemetry metrics and events emitted by Claude Code (names, types, units, attributes), status of the enhanced-telemetry beta, exporter behavior (retry, buffering, temporality, intervals), the complete telemetry config surface (env vars + managed-settings.json), and what changed since the POC (which pinned OTel Collector contrib 0.119.0 and used an enhanced-telemetry beta flag).

**Primary sources used (all claims trace to one of these):**

- [Monitoring (official Claude Code docs)](https://code.claude.com/docs/en/monitoring-usage) — fetched 2026-07-12; the authoritative signals/config reference. Cited below as **[Monitoring]** with section anchors.
- [Environment variables (official Claude Code docs)](https://code.claude.com/docs/en/env-vars) — cited as **[Env-vars]**.
- [Settings (official Claude Code docs)](https://code.claude.com/docs/en/settings) — cited as **[Settings]**.
- [Data usage (official Claude Code docs)](https://code.claude.com/docs/en/data-usage) — cited as **[Data-usage]**.
- [Claude Code CHANGELOG](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md) — cited as **[CHANGELOG vX.Y.Z]**.
- [opentelemetry-collector-contrib releases](https://github.com/open-telemetry/opentelemetry-collector-contrib/releases) — for the current collector version.

Telemetry is opt-in: nothing is exported until `CLAUDE_CODE_ENABLE_TELEMETRY=1` is set and an exporter is configured. Metrics go over the OTel metrics protocol, events over the logs protocol, and (beta) traces over the traces protocol. ([Monitoring — intro](https://code.claude.com/docs/en/monitoring-usage))

---

## 1. Standard attributes (metrics AND events)

All metrics and events share these attributes. ([Monitoring — Standard attributes](https://code.claude.com/docs/en/monitoring-usage#standard-attributes))

| Attribute | Description | Controlled by |
|---|---|---|
| `session.id` | Unique session identifier | `OTEL_METRICS_INCLUDE_SESSION_ID` (default `true`) |
| `app.version` | Claude Code version | `OTEL_METRICS_INCLUDE_VERSION` (default `false`) |
| `app.entrypoint` | Launch surface: `cli`, `sdk-cli`, `sdk-ts`, `sdk-py`, `claude-vscode` | `OTEL_METRICS_INCLUDE_ENTRYPOINT` (default `false`) |
| `organization.id` | Organization UUID (when authenticated) | Always included when available |
| `user.account_uuid` | Account UUID (when authenticated) | `OTEL_METRICS_INCLUDE_ACCOUNT_UUID` (default `true`) |
| `user.account_id` | Tagged account ID matching Anthropic admin APIs, e.g. `user_01BWBeN28...` | `OTEL_METRICS_INCLUDE_ACCOUNT_UUID` (default `true`) |
| `user.id` | Random anonymous installation ID persisted in `~/.claude.json`; not derived from the Claude account | Always included |
| `user.email` | Email (when authenticated via OAuth) — **PII** | Always included when available |
| `terminal.type` | e.g. `iTerm.app`, `vscode`, `cursor`, `tmux` | Always included when detected |
| Keys from `OTEL_RESOURCE_ATTRIBUTES` | Custom team/cost-center attributes; attached to every datapoint and event **and** the OTLP resource block; collisions with built-in keys are ignored (built-in wins) | `OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES` (default `true`) |

Gateway sessions: when signed in via a Claude apps gateway, `user.id` becomes the IdP subject, `user.email` the signed-in email, `user.groups` carries IdP group membership (comma-separated), and every export carries `identity.source: gateway-oidc`. Gateway identity overrides `user.*` / `identity.*` keys set through `OTEL_RESOURCE_ATTRIBUTES`. ([Monitoring — Standard attributes](https://code.claude.com/docs/en/monitoring-usage#standard-attributes))

**Event-only attributes** (never on metrics, to avoid unbounded cardinality) ([same section](https://code.claude.com/docs/en/monitoring-usage#standard-attributes)):

| Attribute | Description |
|---|---|
| `prompt.id` | UUID v4 correlating a user prompt with all subsequent events until the next prompt |
| `workspace.host_paths` | Host workspace directories selected in the desktop app (string array) |
| `workflow.run_id` | Run ID (`wf_...`) on API/tool events from workflow-spawned agents (requires v2.1.202+) |
| `workflow.name` | Workflow name; user-authored names collapse to `custom` unless `OTEL_LOG_TOOL_DETAILS=1` (requires v2.1.202+) |

Every event also carries `event.name`, `event.timestamp` (ISO 8601), and `event.sequence` (monotonic per-session counter). ([Monitoring — Events](https://code.claude.com/docs/en/monitoring-usage#events))

**Resource attributes** (OTLP resource block, all signals) ([Monitoring — Service information](https://code.claude.com/docs/en/monitoring-usage#service-information)): `service.name=claude-code`, `service.version`, `os.type`, `os.version`, `host.arch`, `wsl.version` (WSL only). Meter name: `com.anthropic.claude_code`.

---

## 2. Metric catalog

The docs describe every metric as an incremented counter ("Incremented when...") with the units below; the docs do **not** use OTel instrument-kind terminology, so "counter" here reflects doc language (see Uncertainties). ([Monitoring — Metrics](https://code.claude.com/docs/en/monitoring-usage#metrics) and [Metric details](https://code.claude.com/docs/en/monitoring-usage#metric-details))

| Metric name | Type | Unit | Attributes beyond standard set |
|---|---|---|---|
| `claude_code.session.count` | counter | count | `start_type` (`fresh`, `resume`, `continue`, `agents_view` — the last identifies the `claude agents` dashboard process, not a conversation) |
| `claude_code.lines_of_code.count` | counter | count | `type` (`added`, `removed`); `model` (v2.1.172+) |
| `claude_code.pull_request.count` | counter | count | (standard only). Counts PRs/MRs created via shell **or** MCP tools (v2.1.129+) |
| `claude_code.commit.count` | counter | count | (standard only) |
| `claude_code.cost.usage` | counter | USD | `model`; `query_source` (`main`, `subagent`, `auxiliary`); `speed` (`fast`, absent otherwise); `effort` (`low`/`medium`/`high`/`xhigh`/`max`, absent if unsupported); `agent.name`; `skill.name`; `plugin.name`; `marketplace.name`; `mcp_server.name`; `mcp_tool.name` |
| `claude_code.token.usage` | counter | tokens | `type` (`input`, `output`, `cacheRead`, `cacheCreation`); plus the same attribution set as `cost.usage`: `model`, `query_source`, `speed`, `effort`, `agent.name`, `skill.name`, `plugin.name`, `marketplace.name`, `mcp_server.name`, `mcp_tool.name` |
| `claude_code.code_edit_tool.decision` | counter | count | `tool_name` (`Edit`, `Write`, `NotebookEdit`); `decision` (`accept`, `reject`); `source` (`config`, `hook`, `user_permanent`, `user_temporary`, `user_abort`, `user_reject`); `language` (e.g. `TypeScript`, `unknown` for unrecognized extensions) |
| `claude_code.active_time.total` | counter | s | `type` (`user` = keyboard interactions, `cli` = tool execution / AI responses) |

Redaction rules for the attribution attributes (`agent.name`, `skill.name`, `plugin.name`, `marketplace.name`, `mcp_server.name`, `mcp_tool.name`): built-in / official-marketplace names appear verbatim; user-defined agent names and user-configured MCP server/tool names collapse to `custom`; third-party plugin/skill names collapse to `third-party`; `marketplace.name` is emitted only for official-marketplace plugins. ([Monitoring — Cost counter](https://code.claude.com/docs/en/monitoring-usage#cost-counter))

`model` is available on `token.usage`, `cost.usage`, and (from v2.1.172) `lines_of_code.count`. Per-model commit breakdowns must be approximated by joining on `session.id` with `query_source="main"`. ([Monitoring — Alerting and segmentation](https://code.claude.com/docs/en/monitoring-usage#alerting-and-segmentation))

---

## 3. Event catalog (`claude_code.*` via OTel logs)

24 events documented as of 2026-07-12. Every event carries the standard attributes (section 1) plus `event.name` / `event.timestamp` / `event.sequence`; the table lists only event-specific attributes. "(details)" = requires `OTEL_LOG_TOOL_DETAILS=1`. ([Monitoring — Events](https://code.claude.com/docs/en/monitoring-usage#events), anchors per event)

| Event name | When | Event-specific attributes |
|---|---|---|
| `claude_code.user_prompt` | User submits a prompt | `prompt_length`; `prompt` (redacted unless `OTEL_LOG_USER_PROMPTS=1`); `command_name` (custom/plugin/MCP names collapse to `custom`/`mcp` unless details); `command_source` (`builtin`, `custom`, `mcp`) |
| `claude_code.assistant_response` (v2.1.193+) | After each API request returning text (thinking/tool-use blocks excluded) | `response_length`; `response` (60 KB cap; `<REDACTED>` unless `OTEL_LOG_ASSISTANT_RESPONSES=1`; falls back to `OTEL_LOG_USER_PROMPTS` when unset); `model`; `request_id`; `query_source` |
| `claude_code.tool_result` | Tool completes execution (not emitted for rejected calls) | `tool_name`; `tool_use_id` (joins to hooks, `tool_decision`, spans); `success` (`"true"`/`"false"`); `duration_ms`; `error_type`; `error` (details); `decision_type` (always `accept`); `decision_source` (`config`, `hook`, `user_permanent`, `user_temporary`); `tool_input_size_bytes`; `tool_result_size_bytes`; `mcp_server_scope`; `tool_parameters` (details; per-tool JSON: Bash → `bash_command`, `full_command`, `timeout`, `description`, `dangerouslyDisableSandbox`, `git_commit_id`; WorkspaceBash → `bash_command`, `full_command`, `timeout`; MCP → `mcp_server_name`, `mcp_tool_name`; Skill → `skill_name`; Agent/Task → `subagent_type`); `tool_input` (details; JSON args, values >512 chars truncated, payload ~4 K cap) |
| `claude_code.api_request` | Each API request to Claude | `model`; `cost_usd`; `duration_ms`; `input_tokens`; `output_tokens`; `cache_read_tokens`; `cache_creation_tokens`; `request_id`; `speed` (`fast`/`normal`); `query_source`; `effort`; `agent.name`; `skill.name`; `plugin.name`; `marketplace.name`; `mcp_server.name`; `mcp_tool.name` |
| `claude_code.api_error` | API request fails (terminal, after internal retries) | `model`; `error`; `status_code` (number; absent for non-HTTP errors); `duration_ms`; `attempt` (total attempts incl. first); `request_id`; `speed`; `query_source`; `effort`; attribution set as above |
| `claude_code.api_refusal` | Response has `stop_reason: "refusal"` (arrives on success stream, so `api_error` doesn't fire) | `model`; `request_id`; `query_source`; `speed`; `attempt`; `effort`; `server_fallback_hop`; `has_category`; `has_explanation`; `category` (details + `has_category=true`; one of `cyber`, `bio`, `frontier_llm`, `reasoning_extraction`); attribution set |
| `claude_code.api_request_body` | Per API attempt when `OTEL_LOG_RAW_API_BODIES` set | `body` (inline mode `=1`; 60 KB cap; thinking redacted); `body_ref` (file mode `=file:<dir>`; path to `<uuid>.request.json`); `body_length`; `body_truncated`; `model`; `query_source` |
| `claude_code.api_response_body` | Per successful response when `OTEL_LOG_RAW_API_BODIES` set | `body` / `body_ref` (`<request_id>.response.json`) / `body_length` / `body_truncated`; `model`; `query_source`; `request_id` |
| `claude_code.tool_decision` | Tool permission decision made | `tool_name`; `tool_use_id`; `decision` (`accept`/`reject`); `source` (`config`, `hook`, `user_permanent`, `user_temporary`, `user_abort`, `user_reject` — interactive-CLI vs SDK emission semantics differ per docs); `tool_parameters` (details; same shape as `tool_result` minus post-execution fields; may reflect `updatedInput` rewrites) |
| `claude_code.permission_mode_changed` | Permission mode changes | `from_mode` / `to_mode` (`default`, `plan`, `acceptEdits`, `auto`, `bypassPermissions`); `trigger` (`shift_tab`, `exit_plan_mode`, `auto_gate_denied`, `auto_opt_in`; absent for SDK/bridge) |
| `claude_code.auth` | `/login` or `/logout` completes | `action` (`login`/`logout`); `success`; `auth_method` (e.g. `oauth`); `error_category` (raw message never included); `status_code` (string) |
| `claude_code.mcp_server_connection` | MCP server connects / disconnects / fails | `status` (`connected`, `failed`, `disconnected`); `transport_type` (`stdio`, `sse`, `http`); `server_scope` (`user`, `project`, `local`); `duration_ms`; `error_code`; `is_plugin`; `plugin_id_hash` (if plugin); `plugin.name` (if plugin; third-party → `"third-party"` unless details); `server_name` (details); `error` (details) |
| `claude_code.internal_error` | Unexpected internal error caught (not emitted on Bedrock / GCP Agent Platform / Foundry, or with `DISABLE_ERROR_REPORTING`) | `error_name` (class name only); `error_code` (errno, e.g. `ENOENT`) — message/stack never included |
| `claude_code.plugin_installed` | Plugin install finishes (CLI or `/plugin` UI) | `marketplace.is_official`; `install.trigger` (`cli`/`ui`); `plugin.name`, `plugin.version`, `marketplace.name` (third-party marketplaces: details only) |
| `claude_code.plugin_loaded` | Once per enabled plugin at session start | `plugin.name` (non-official → `third-party` unless details); `marketplace.name`; `plugin.version`; `plugin.scope` (`official`, `org`, `user-local`, `default-bundle`); `enabled_via` (`default-enable`, `org-policy`, `seed-mount`, `user-install`); `plugin_id_hash`; `has_hooks`; `has_mcp`; `host_owned_mcp` (v2.1.172+); `skill_path_count`; `command_path_count`; `agent_path_count`; `safe_mode` (v2.1.169+) |
| `claude_code.skill_activated` | Skill invoked (Skill tool or `/` command) | `skill.name` (user-defined/third-party → `custom_skill` unless details); `invocation_trigger` (`user-slash`, `claude-proactive`, `nested-skill`); `skill.source` (`bundled`, `userSettings`, `projectSettings`, `plugin`); `skill.kind` (`workflow` or absent); `plugin.name`, `marketplace.name` (details or official marketplace) |
| `claude_code.at_mention` | `@`-mention resolved (early-exit paths don't emit) | `mention_type` (`file`, `directory`, `agent`, `mcp_resource`); `success` |
| `claude_code.api_retries_exhausted` | Request fails after >1 attempt (alongside final `api_error`) | `model`; `error`; `status_code`; `total_attempts`; `total_retry_duration_ms`; `speed` |
| `claude_code.hook_registered` | Once per configured hook at session start | `hook_event`; `hook_type` (`command`, `prompt`, `mcp_tool`, `http`, `agent`); `hook_source` (`userSettings`, `projectSettings`, `localSettings`, `flagSettings`, `policySettings`, `pluginHook`); `safe_mode` (v2.1.169+); `hook_matcher` (details); `plugin.name`, `plugin_id_hash` (when `pluginHook`) |
| `claude_code.hook_execution_start` | Hooks begin executing for a hook event | `hook_event`; `hook_name` (e.g. `PreToolUse:Write`); `num_hooks`; `managed_only`; `hook_source` (`policySettings`/`merged`); `safe_mode`; `hook_definitions` (detailed beta tracing + details only) |
| `claude_code.hook_execution_complete` | All hooks for a hook event finished | `hook_event`; `hook_name`; `num_hooks`; `num_success`; `num_blocking`; `num_non_blocking_error`; `num_cancelled`; `total_duration_ms`; `managed_only`; `hook_source`; `safe_mode`; `hook_definitions` (same gating) |
| `claude_code.hook_plugin_metrics` | Official-marketplace plugin hook emits per-invocation metrics | `plugin_id` (`<name>@<marketplace>`); `hook_event`; up to 20 plugin-emitted keys matching `^[a-z][a-z0-9_]{0,39}$` (boolean/number values) |
| `claude_code.compaction` | Conversation compaction completes | `trigger` (`auto`/`manual`); `success`; `duration_ms`; `pre_tokens`; `post_tokens`; `error`; `precompute_reuse` (manual only; `hit`, `miss_custom_instructions`, `miss_hook`, `miss_not_ready`; v2.1.153+) |
| `claude_code.feedback_survey` | Session quality survey shown/answered | `event_type` (`appeared`, `responded`, `transcript_prompt_appeared`); `appearance_id`; `survey_type` (`session`); `response`; `enabled_via_override` (boolean; present when `CLAUDE_CODE_ENABLE_FEEDBACK_SURVEY_FOR_OTEL` is set) |

PII/redaction note for downstream design: prompt text, response text, tool params/inputs, tool content, and raw API bodies are all **off by default**, each behind its own gate (`OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_ASSISTANT_RESPONSES`, `OTEL_LOG_TOOL_DETAILS`, `OTEL_LOG_TOOL_CONTENT`, `OTEL_LOG_RAW_API_BODIES`). `user.email` is always included when OAuth-authenticated and must be redacted backend-side if that's a concern. Extended-thinking content is always redacted from raw bodies. ([Monitoring — Security and privacy](https://code.claude.com/docs/en/monitoring-usage#security-and-privacy))

---

## 4. Enhanced telemetry / beta tracing

Current state (verified 2026-07-12, [Monitoring — Traces (beta)](https://code.claude.com/docs/en/monitoring-usage#traces-beta)):

- **Flag name:** `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` (the older `ENABLE_ENHANCED_TELEMETRY_BETA` is also accepted). There is no `OTEL_ENABLE_EXTENDED_TELEMETRY` variable in the current docs.
- **What it gates:** distributed **traces** (spans), still explicitly labeled **beta** — not GA. Requires `CLAUDE_CODE_ENABLE_TELEMETRY=1` + `OTEL_TRACES_EXPORTER` (`otlp`/`console`/`none`). Traces reuse the common OTLP endpoint/protocol/header/mTLS config, with per-signal overrides `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL` / `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` and `OTEL_TRACES_EXPORT_INTERVAL` (default 5000 ms).
- **Span hierarchy:** `claude_code.interaction` (root per user prompt) → `claude_code.llm_request`, `claude_code.hook` (detailed beta only), `claude_code.tool` → `claude_code.tool.blocked_on_user` + `claude_code.tool.execution` (+ nested subagent spans under Agent-tool spans). Every span carries the standard attributes plus `span.type`. `llm_request`, `tool.execution`, and `hook` set OTel status `ERROR` on failure; others end `UNSET`.
- **Notable span attributes:** `llm_request` carries `model`, GenAI semconv fields (`gen_ai.system=anthropic`, `gen_ai.request.model`, `gen_ai.response.id`, `gen_ai.response.finish_reasons`), token counts, `ttft_ms`, `duration_ms`, `request_id`, `client_request_id`, `attempt`, `stop_reason`, `agent_id`/`parent_agent_id`, `workflow.run_id`/`workflow.name`; retries appear as `gen_ai.request.attempt` span events. `tool` spans carry `tool_use_id`/`gen_ai.tool.call.id` (joinable to `tool_result`/`tool_decision` events and hook payloads) and gated `file_path`/`full_command`/`skill_name`/`subagent_type`. Spans redact prompts/tool details/content by default under the same `OTEL_LOG_*` gates.
- **Trace context propagation:** Bash/PowerShell subprocesses get `TRACEPARENT`; the Anthropic API request carries a W3C `traceparent` header (recorded `traceresponse` as span link); SDK/`-p` sessions read inbound `TRACEPARENT`/`TRACESTATE`; interactive sessions ignore inbound values. Propagation through a custom `ANTHROPIC_BASE_URL` proxy requires `CLAUDE_CODE_PROPAGATE_TRACEPARENT=1` (added v2.1.152 — [Env-vars](https://code.claude.com/docs/en/env-vars)).
- **A second, deeper tier exists:** "detailed beta tracing" requires `ENABLE_BETA_TRACING_DETAILED=1` **and** `BETA_TRACING_ENDPOINT`, and in interactive CLI sessions an org allowlist (SDK/`-p` sessions are not gated). It adds the `claude_code.hook` span and content-bearing attributes (`new_context`, `system_prompt_preview`, `user_system_prompt`, `tool_input`, `response.model_output`) that are explicitly "not part of the stable span schema."
- **No GA announcement** for traces appears in the docs or CHANGELOG as of 2026-07-12; metrics and log events carry no beta label and are the stable surface.

---

## 5. Exporter behavior

Verified against [Monitoring — Quick start / Common configuration variables](https://code.claude.com/docs/en/monitoring-usage#configuration-details) and [Env-vars](https://code.claude.com/docs/en/env-vars):

| Behavior | Documented value |
|---|---|
| Metrics export interval | `OTEL_METRIC_EXPORT_INTERVAL`, default **60000 ms** |
| Logs export interval | `OTEL_LOGS_EXPORT_INTERVAL`, default **5000 ms** (raised from 1 s in v1.0.8 — [CHANGELOG v1.0.8]) |
| Traces export interval | `OTEL_TRACES_EXPORT_INTERVAL`, default **5000 ms** (span batch) |
| Temporality | `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE`, default **`delta`**; set `cumulative` for backends that require it |
| Span flush timeout | `CLAUDE_CODE_OTEL_FLUSH_TIMEOUT_MS`, default 5000 ms |
| Shutdown flush timeout | `CLAUDE_CODE_OTEL_SHUTDOWN_TIMEOUT_MS`, default 2000 ms — "increase if metrics are dropped at exit" ([Env-vars]) |
| Exporter diagnostics | `CLAUDE_CODE_OTEL_DIAG_STDERR=1` (v2.1.179+) writes exporter errors to stderr; otherwise only visible with `--debug` — misconfigured exporters otherwise **fail silently** ([Env-vars]) |
| Protocols | `grpc`, `http/json`, `http/protobuf`; per-signal overrides for metrics/logs/traces |
| Proxy | OTLP export honors `HTTP_PROXY`/`HTTPS_PROXY` ([CHANGELOG v2.0.17]) |
| Subprocess isolation | Since v2.1.128, subprocesses (Bash, hooks, MCP, LSP) do **not** inherit `OTEL_*` env vars ([Monitoring — Administrator configuration]; [CHANGELOG v2.1.128]) |
| Dynamic auth headers | `otelHeadersHelper` setting (script emitting JSON headers), HTTP protocols only (gRPC uses static `OTEL_EXPORTER_OTLP_HEADERS`); refreshed every `CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS` (default 1740000 ms / 29 min) ([Monitoring — Dynamic headers]) |
| mTLS | HTTP protocols: `CLAUDE_CODE_CLIENT_CERT` / `CLAUDE_CODE_CLIENT_KEY` / `CLAUDE_CODE_CLIENT_KEY_PASSPHRASE` + `NODE_EXTRA_CA_CERTS`; gRPC: `OTEL_EXPORTER_OTLP_CLIENT_KEY` / `OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE` (+ per-signal variants) + `OTEL_EXPORTER_OTLP_CERTIFICATE` ([Monitoring — mTLS authentication]) |

**Retry semantics — important distinction:** the documented retry behavior is for **API requests**, not the OTLP exporter. Claude Code retries failed API calls internally and emits a single terminal `api_error` (plus `api_retries_exhausted` when >1 attempt); `CLAUDE_CODE_MAX_RETRIES` defaults to 10, capped at 15 (v2.1.186+), cap removed by `CLAUDE_CODE_RETRY_WATCHDOG` (v2.1.199+), so terminal `attempt` = 11 by default, ≤16 without the watchdog. ([Monitoring — Detect retry exhaustion](https://code.claude.com/docs/en/monitoring-usage#detect-retry-exhaustion)) **OTLP-exporter retry/queueing/backpressure behavior is not documented anywhere in the official docs** — see Uncertainties.

**Ingest-reliability implications** (documented): default `delta` temporality means dropped export batches are lost counts (no cumulative recovery); the 2 s shutdown timeout can drop tail data on exit; exporter failures are silent unless `CLAUDE_CODE_OTEL_DIAG_STDERR` or `--debug` is on. For collector-side buffering/retry, put an OTel Collector in front (the docs' SIEM guidance assumes this pattern — [Monitoring — Send events to a SIEM]).

---

## 6. Complete telemetry config surface

### 6.1 Core enable + exporters ([Monitoring — Common configuration variables](https://code.claude.com/docs/en/monitoring-usage#configuration-details))

| Variable | Purpose / values | Default |
|---|---|---|
| `CLAUDE_CODE_ENABLE_TELEMETRY` | Master switch for OTel export (required) | off |
| `OTEL_METRICS_EXPORTER` | `console`, `otlp`, `prometheus`, `none` (comma-separated) | unset |
| `OTEL_LOGS_EXPORTER` | `console`, `otlp`, `none` | unset |
| `OTEL_TRACES_EXPORTER` | `console`, `otlp`, `none` (beta; needs enhanced-telemetry flag) | unset |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc`, `http/json`, `http/protobuf` (all signals) | — |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP endpoint (all signals) | — |
| `OTEL_EXPORTER_OTLP_METRICS_PROTOCOL` / `..._METRICS_ENDPOINT` | Per-signal override (metrics) | — |
| `OTEL_EXPORTER_OTLP_LOGS_PROTOCOL` / `..._LOGS_ENDPOINT` | Per-signal override (logs) | — |
| `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL` / `..._TRACES_ENDPOINT` | Per-signal override (traces) | — |
| `OTEL_EXPORTER_OTLP_HEADERS` | Static auth headers | — |
| `OTEL_METRIC_EXPORT_INTERVAL` | ms | 60000 |
| `OTEL_LOGS_EXPORT_INTERVAL` | ms | 5000 |
| `OTEL_TRACES_EXPORT_INTERVAL` | ms | 5000 |
| `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE` | `delta` / `cumulative` | `delta` |
| `OTEL_RESOURCE_ATTRIBUTES` | Custom `k=v,k=v` attributes (strict format: no spaces, US-ASCII minus control/quote/comma/semicolon/backslash; percent-encode others) | — |

### 6.2 Content gates (PII surface) ([Monitoring]; [Env-vars])

| Variable | Reveals | Default |
|---|---|---|
| `OTEL_LOG_USER_PROMPTS` | Prompt text on events + spans | off |
| `OTEL_LOG_ASSISTANT_RESPONSES` (v2.1.193+) | Response text on `assistant_response`; **falls back to `OTEL_LOG_USER_PROMPTS` when unset** (set `0` to keep redacted) | off |
| `OTEL_LOG_TOOL_DETAILS` | Tool params/inputs (Bash commands, MCP server/tool names, skill names, file paths, workflow names, verbatim command names, full error messages, refusal `category`) | off |
| `OTEL_LOG_TOOL_CONTENT` | Tool input+output bodies in span events (60 KB cap; requires tracing) | off |
| `OTEL_LOG_RAW_API_BODIES` | Full Messages API request/response JSON (`=1` inline 60 KB, `=file:<dir>` untruncated on disk + `body_ref`); implies consent to all other content gates; thinking always redacted | off |

### 6.3 Metrics cardinality controls ([Monitoring — Metrics cardinality control](https://code.claude.com/docs/en/monitoring-usage#metrics-cardinality-control))

| Variable | Attribute | Default |
|---|---|---|
| `OTEL_METRICS_INCLUDE_SESSION_ID` | `session.id` | `true` |
| `OTEL_METRICS_INCLUDE_VERSION` | `app.version` | `false` |
| `OTEL_METRICS_INCLUDE_ACCOUNT_UUID` | `user.account_uuid` + `user.account_id` | `true` |
| `OTEL_METRICS_INCLUDE_ENTRYPOINT` (v2.1.152+) | `app.entrypoint` | `false` |
| `OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES` (v2.1.161+) | `OTEL_RESOURCE_ATTRIBUTES` keys as datapoint labels | `true` |

### 6.4 Beta / operational / adjacent ([Monitoring]; [Env-vars]; [Data-usage])

| Variable | Purpose |
|---|---|
| `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA` (alias `ENABLE_ENHANCED_TELEMETRY_BETA`) | Enable beta span tracing |
| `ENABLE_BETA_TRACING_DETAILED` + `BETA_TRACING_ENDPOINT` | Detailed beta tracing tier (hook spans, content attributes; org-allowlisted in interactive CLI) |
| `CLAUDE_CODE_PROPAGATE_TRACEPARENT` (v2.1.152+) | Propagate W3C trace context through custom `ANTHROPIC_BASE_URL` proxies |
| `CLAUDE_CODE_OTEL_DIAG_STDERR` (v2.1.179+) | Exporter diagnostics to stderr |
| `CLAUDE_CODE_OTEL_FLUSH_TIMEOUT_MS` / `CLAUDE_CODE_OTEL_SHUTDOWN_TIMEOUT_MS` | Span flush (5000) / shutdown (2000) timeouts |
| `CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS` | Dynamic-header refresh interval (default 29 min) |
| `otelHeadersHelper` (settings.json key, not env) | Script emitting JSON auth headers (HTTP protocols only) |
| `CLAUDE_CODE_ENABLE_FEEDBACK_SURVEY_FOR_OTEL` (v2.1.136+) | Route session-quality survey events to your collector when Anthropic-bound traffic is blocked |
| `CLAUDE_CODE_ACCOUNT_UUID` / `CLAUDE_CODE_USER_EMAIL` / `CLAUDE_CODE_ORGANIZATION_UUID` (v2.1.51+) | SDK callers supply account identity synchronously so early events carry it ([CHANGELOG v2.1.51]) |
| `DISABLE_TELEMETRY` / `DO_NOT_TRACK` | Opt out of **Anthropic's own operational telemetry** (Statsig-style usage metrics; also disables feature-flag fetching). Separate data path from your OTel export ([Env-vars]; [Data-usage — Telemetry services]) |
| `DISABLE_ERROR_REPORTING` | Opt out of Sentry error logging; also suppresses the `internal_error` OTel event ([Env-vars]; [Monitoring — Internal error event]) |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | Umbrella = `DISABLE_AUTOUPDATER` + `DISABLE_FEEDBACK_COMMAND` + `DISABLE_ERROR_REPORTING` + `DISABLE_TELEMETRY` ([Env-vars]) |
| `CLAUDE_CODE_MAX_RETRIES` / `CLAUDE_CODE_RETRY_WATCHDOG` | API retry count (affects `attempt` semantics on `api_error`) |

### 6.5 Managed settings (fleet-wide) ([Monitoring — Administrator configuration](https://code.claude.com/docs/en/monitoring-usage#administrator-configuration); [Settings](https://code.claude.com/docs/en/settings))

- All telemetry env vars can be forced fleet-wide via the `env` block of managed settings. Documented example: `{"env": {"CLAUDE_CODE_ENABLE_TELEMETRY": "1", "OTEL_METRICS_EXPORTER": "otlp", "OTEL_LOGS_EXPORTER": "otlp", "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc", "OTEL_EXPORTER_OTLP_ENDPOINT": "...", "OTEL_EXPORTER_OTLP_HEADERS": "..."}}`. "Environment variables defined in the managed settings file have high precedence and can't be overridden by users."
- **Precedence:** Managed (highest, cannot be overridden) → CLI args → local (`.claude/settings.local.json`) → project (`.claude/settings.json`) → user (`~/.claude/settings.json`). ([Settings — How scopes interact])
- **Delivery mechanisms:** server-managed (claude.ai admin console or self-hosted gateway, delivered at sign-in), MDM (macOS `com.anthropic.claudecode` plist, Windows HKLM/HKCU registry), or file-based `managed-settings.json` in system directories, with a systemd-style `managed-settings.d/` drop-in directory (alphabetical merge; scalars override, arrays concat+dedupe, objects deep-merge). Legacy Windows path `C:\ProgramData\ClaudeCode\managed-settings.json` unsupported since v2.1.75 (now `C:\Program Files\ClaudeCode\managed-settings.json`). ([Settings — Managed settings])
- Managed settings parse **tolerantly** (v2.1.169+): an invalid entry is stripped with a warning, the rest of the policy still enforces. User/project/local files remain strict. ([Settings — Invalid entries in managed settings])
- Security note: untrusted project settings can no longer set OTel client-certificate paths without trust confirmation (fixed in v2.1.169). ([CHANGELOG v2.1.169])

---

## 7. Changes since POC (early 2025 → 2026-07)

The POC pinned OTel Collector contrib **0.119.0** (Feb 2025 era) and used an enhanced-telemetry beta flag. Latest collector-contrib release as of 2026-07-12: **v0.156.0** (published 2026-07-07) — 37 minor releases behind. ([collector-contrib releases](https://github.com/open-telemetry/opentelemetry-collector-contrib/releases))

Telemetry-relevant Claude Code changes, from the [CHANGELOG](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md) (versions verified against changelog headers):

**New events**
- v2.1.193 — `claude_code.assistant_response` event added, with `OTEL_LOG_ASSISTANT_RESPONSES` gate. **Upgrade hazard:** deployments already setting `OTEL_LOG_USER_PROMPTS=1` silently start receiving response text unless `OTEL_LOG_ASSISTANT_RESPONSES=0` is set.
- v2.1.122 — `claude_code.at_mention` event added.
- v2.1.111 — `OTEL_LOG_RAW_API_BODIES` added (→ `api_request_body` / `api_response_body` events).
- v2.1.126 — `skill_activated` now fires for user-typed slash commands; new `invocation_trigger` attribute.

**New metric/event attributes**
- v2.1.202 — `workflow.run_id` / `workflow.name` on workflow-spawned agents' telemetry.
- v2.1.172 — `model` attribute on `claude_code.lines_of_code.count`.
- v2.1.161 — `OTEL_RESOURCE_ATTRIBUTES` keys now attached as **metric datapoint labels** (new `OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES` control). Schema-affecting for star-schema design.
- v2.1.152 — `app.entrypoint` attribute (opt-in `OTEL_METRICS_INCLUDE_ENTRYPOINT`).
- v2.1.119 — `tool_use_id` on `tool_result`/`tool_decision`; `tool_input_size_bytes` on `tool_result`.
- v2.1.117 — `command_name`/`command_source` on `user_prompt`; `effort` on `cost.usage`, `token.usage`, `api_request`, `api_error`.
- v2.1.41 — `speed` attribute (fast mode) on events and spans.
- v2.1.139 / v2.1.145 — `agent_id`/`parent_agent_id` on `llm_request` and `tool` spans.
- v2.1.121 — `stop_reason`, `gen_ai.response.finish_reasons`, `user_system_prompt` on LLM request spans.

**Type/semantics changes (breaking for ingest)**
- v2.1.122 — numeric attributes on `api_request`/`api_error` are now emitted as **numbers, not strings**.
- v2.1.129 — `pull_request.count` now also counts MCP-created PRs/MRs.
- v2.1.128 — subprocesses no longer inherit `OTEL_*` env vars.
- v2.1.85 — `tool_parameters` on `tool_result` moved behind `OTEL_LOG_TOOL_DETAILS=1` (was previously less gated); crash fix for exporters set to `none`.
- v2.1.157 — `tool_decision` gained `tool_parameters` under the details gate.

**Tracing (the beta the POC used)**
- v2.1.97/v2.1.98 — `TRACEPARENT` inheritance for Bash subprocesses; interaction spans wrap full turns under concurrent SDK calls.
- v2.1.101 — beta tracing now honors `OTEL_LOG_USER_PROMPTS` / `OTEL_LOG_TOOL_DETAILS` / `OTEL_LOG_TOOL_CONTENT`; sensitive span attributes no longer emitted unless opted in (**redaction tightened vs. early beta**).
- v2.1.110 — SDK/headless sessions read inbound `TRACEPARENT`/`TRACESTATE`.
- v2.1.152 — `CLAUDE_CODE_PROPAGATE_TRACEPARENT` for custom proxies.
- v2.1.141 — fixed early spans silently dropped in SDK/headless with beta tracing.
- Still labeled beta in docs; no rename of the flag, no GA.

**Reliability / correctness fixes relevant to ingest**
- v2.1.161 — fixed events (`user_prompt`, `api_request`, `tool_result`, `tool_decision`) silently dropped when emitted before telemetry init completed.
- v2.1.139 — fixed `active_time.total` not emitted in `--print` mode.
- v2.1.47 — fixed `tool_decision` not emitted in headless/SDK mode.
- v2.1.120 — fixed `DISABLE_TELEMETRY`/`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` not suppressing usage-metrics telemetry for API/enterprise users.
- v2.1.149 / v2.1.179 — `otelHeadersHelper` failures surfaced in `/doctor`+debug log; `CLAUDE_CODE_OTEL_DIAG_STDERR` added.
- v2.1.51 — `CLAUDE_CODE_ACCOUNT_UUID`/`CLAUDE_CODE_USER_EMAIL`/`CLAUDE_CODE_ORGANIZATION_UUID` for SDK callers (fixes early events missing account metadata).
- v2.1.136 — `CLAUDE_CODE_ENABLE_FEEDBACK_SURVEY_FOR_OTEL` (→ `feedback_survey` events to your collector).

**Pre-2.x baseline (for context vs. an early-2025 POC)**
- v1.0.8 — default logs export interval raised 1 s → 5 s.
- v1.0.28 — `terminal.type`, `language` attributes added.
- v1.0.39 — Active Time metric added.
- v1.0.51 — resource gained `os.type`, `os.version`, `host.arch`, `wsl.version`.
- v1.0.126 — mTLS for HTTP-based exporters.
- v2.0.17 — OTLP export honors `HTTP_PROXY`/`HTTPS_PROXY`.

---

## 8. Uncertainties (not verifiable against primary sources)

1. **Metric instrument kinds:** the docs never state OTel instrument types (Counter vs UpDownCounter vs Histogram). All eight metrics are described as incremented counts with monotonic language, and the temporality-preference doc implies sums, but "counter" in section 2 is an inference from doc wording, not an explicit doc claim. No histograms are documented.
2. **OTLP exporter retry/queueing/backpressure:** no primary source documents whether the embedded OTel JS SDK exporters retry failed OTLP exports, queue sizes, or drop policies. Only flush/shutdown timeouts (`CLAUDE_CODE_OTEL_FLUSH_TIMEOUT_MS`, `CLAUDE_CODE_OTEL_SHUTDOWN_TIMEOUT_MS`) and the silent-failure/diagnostics behavior are documented. Assume at-most-once delivery from the CLI and put a collector in front for durability.
3. **Prometheus exporter details:** `prometheus` is a documented `OTEL_METRICS_EXPORTER` value and a "Prometheus port collision" failure mode is mentioned under `CLAUDE_CODE_OTEL_DIAG_STDERR`, but the listen port/address and how to change them are not documented.
4. **`api_error` emission semantics ambiguity:** the event catalog says `api_error` is "logged when an API request to Claude fails," while the "Detect retry exhaustion" section says a *single* `api_error` is emitted only after retries are exhausted (terminal). The docs themselves note intermediate retries are not logged, so the terminal reading is authoritative, but the two sections read inconsistently.
5. **`tool_decision` `source` vs `decision_type`/`decision_source` naming:** `tool_decision` uses `decision`/`source` while `tool_result` uses `decision_type`/`decision_source` for the same concepts. Both verified in the doc; flagged because the asymmetry is easy to get wrong in a star schema.
6. **Exact collector-contrib compatibility:** no Anthropic primary source recommends a specific OTel Collector version; v0.156.0 (2026-07-07) is simply the latest contrib release. Whether anything between 0.119.0 and 0.156.0 breaks a POC pipeline (e.g. config schema changes in receivers/exporters) was not assessed here.
7. **Enhanced-telemetry flag history:** the CHANGELOG does not record when `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA` was introduced or whether it was renamed from an earlier flag the POC used ("`ENABLE_ENHANCED_TELEMETRY_BETA` is also accepted" suggests a rename happened, but no primary source states it).
8. **`OTEL_LOGS_EXPORT_INTERVAL` / per-signal interval vars are Claude Code-specific extensions** in effect (the OTel spec defines `OTEL_METRIC_EXPORT_INTERVAL` but logs/traces interval vars are not standard SDK spec vars); the docs present them without noting this. Treat them as Claude Code behavior, not portable OTel config.
9. **Event count completeness:** the 24 events above are everything on the current Monitoring page. Undocumented events may exist (e.g. the CHANGELOG mentions rate-limit telemetry counting at v2.1.196 with no corresponding documented event); anything not on the Monitoring page should be treated as unstable/internal.
