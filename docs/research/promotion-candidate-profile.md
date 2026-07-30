# Promotion-candidate profile — the Jul 18 -> Jul 28 reservoir window

**Ticket:** #351 (part of wayfinder map #350) · **Date:** 2026-07-28

**Question:** over the reconciled reservoir window, what is the true profile of every `kept`
and `unclassified` attribute key — and what is the smallest partition of them (at most three
groups) that lets a grilling session argue each group's value case coherently?

**Artifact:** `analysis/promotion_profile.py`. This file is a frozen cut; re-run the notebook
for a fresh one. Nothing here decides a promotion — the three grilling groups do that.

## What was measured

17,915 blobs over 11 days (`dt=2026-07-18` -> `2026-07-28`), decoding to **592,741 records**
— 251,700 metric data points, 232,050 log records and 108,991 resource blocks — across
**699 sessions** and **20 seats**. Full-window read: about 10 minutes.

The profile is at **record** grain, not blob grain, so a key's fill rate is a share of the
records of *its own* signal name rather than of every blob in the window. Each key also
carries the distinct sessions and seats it reaches, its value cardinality, and — for keys
with at most 25 distinct values — the seat count behind each value.

Of 654 distinct key paths: **324 promoted, 182 kept, 148 unclassified, 0 denied**. The
unclassified 148 decompose exactly: 114 are resource attributes seen again under a signal key
path, 18 are `process.owner` — both owned by #353 — and **16 are genuinely new**. Dropping
those two sets plus the 22 `event.timestamp` paths, and collapsing wildcard-registered keys to
their registry grain, leaves **96 decision rows**, tabled in full at the bottom.

**One reading caveat.** Identity rides on the record's own attributes, and a `resource` block
carries `user.email` / `session.id` only when the `cc-otel.statusline` wrapper wrote it
(2,006 of 108,991 blocks). Session and seat counts on `resource/*` rows therefore read 0 by
construction — that is the OTLP shape, not absent data.

## What the wide window changed

The charting sweep read 7 days and 10,137 payloads and found 82 distinct candidate attribute
keys. Doubling the window did not mostly add keys — it changed verdicts:

1. **`terminal.type` is the map's biggest finding, and it is not a bot account.**
   `non-interactive` accounts for 69,469 metric records (32% of those carrying the key) and
   90,126 event records (43%) — spread across **15 of the 19 seats** that report a terminal.
   Every per-seat and per-session adoption reading in the marts today pools headless runs
   with human ones, across three quarters of the roster.

2. **The largest unclassified key in the window was not on anyone's list.**
   `events/tool_decision/tool_source` — 45,244 records, 96% fill, 18 seats, three values
   (`builtin` 44,267 / `mcp` 964 / `sdk_host_builtin_mcp` 13). It is the only direct measure
   of how much tool use is MCP rather than native, and MCP tool use turns out to be 2% of
   tool decisions concentrated in 5 seats.

3. **Seventeen keys can be closed without a grilling session** because they are constant over
   593K records (see *Settled by the evidence*). That is roughly a fifth of the decision set removed
   by measurement rather than argument.

4. **The families the charting session dismissed on thin evidence split three ways.**
   `plugin_loaded` (1,475 records, 377 sessions, 14 seats) and `hook_registered` (2,162 / 363
   / 12) argue for themselves comfortably. `internal_error` (79 / 11 seats) and `api_error`
   (28 / 8 seats) are thin but are reliability readings where low counts are the point.
   `compaction` (54 records, **3 seats**) and `feedback_survey` (54 / 8 seats) confirm the
   map's suspicion — too thin for a trend, at most a card. `permission_mode_changed` has
   nothing to argue: all three of its attributes are already promoted.

5. **New unclassified keys the sweep had not surfaced:**
   `subagent_completed/final_model` (794 records, 7 models incl. `claude-sonnet-5` 482 and
   `claude-opus-4-8[1m]` 171) and `model_swapped`; `feedback_survey/event_origin` and
   `event_origin_server`; `assistant_response/message.uuid` (21,038) and
   `user_prompt/message.uuid`; and `tool_parameters` on both tool events (21,610 / 21,545) —
   which the sink's redaction already sweeps inside while the registry has no row for it.

6. **"Cost per MCP server is uncomputable from the marts today" (#353) is not right.**
   `raw.events` carries `mcp_server_name` on `api_request` rows, and those rows carry
   `cost_usd`: 1,987 rows and $246.23 over the window, decomposing cleanly by server
   (`custom` $137.76, `claude_ai_Microsoft_Learn` $59.70, `plugin_microsoft-docs_microsoft-learn`
   $38.72, …). What is missing is a **mart**, not a column — `marts.bridge_session_mcp` maps
   session to MCP name and carries no cost. Promoting `mcp_server.name` / `mcp_tool.name` on
   `claude_code.cost.usage` adds a *second* attribution path, and that is the question, not
   whether attribution exists at all.

## The proposed partition

Three groups, cut by **decision axis** rather than by event family. Group A is grilled first
and blocks the other two: every key in it changes the denominator that B and C argue against.
B and C are independent of each other and can run in parallel.

### Group A — Population and surface: the keys that move a denominator

**Axis:** each of these changes *what counts as a session, a seat or a machine*, so every
other value case in the map is only arguable once they are settled. Grilled first; blocks B
and C.

| Key | Records | Seats | Card | The denominator it moves |
|---|---|---|---|---|
| `*` / **terminal.type** (metrics + events) | 219,208 + 211,875 | 19 | 4 | `non-interactive` is 32% of metric records and 43% of event records carrying the key, across **15 of 19 seats**. Every per-seat and per-session adoption reading today pools headless runs with human ones. |
| `*` / **user.id** (metrics + events) | 243,676 + 232,050 | 20 | 53 | Anonymous install id — the machine, not the person. 53 installs behind 20 seats, so it separates one developer on three machines from three developers. |
| `resource` / **service.name** | 108,991 | - | 3 | `claude-code` 108,512 · `claude-code-desktop` 345 · `cowork` 134 — three products inside one adoption number. |
| `resource` / **os.type**, **os.version**, **wsl.version** | 106,985 · 106,985 · 11,577 | - | 2 · 2 · 1 | Fleet composition. `wsl.version` is present on 11% of resource blocks, so WSL and native Windows are indistinguishable in the marts today. Constant value, but *presence* is the signal. |
| `resource` / **claude.deployment_mode** | 479 | - | 1 | `1p` marks Anthropic-internal rows. If any reach the marts they inflate every count — again a presence signal, not a value one. |
| `events` / `*` / **workflow.name**, **workflow.run_id** | 216 each | 1 | 1 | Workflow-spawned agent sessions. One seat so far, but a denominator key has to exist before the population shifts. |
| `events` / `*` / **workspace.host_paths** | 110 | 1 | 3 | Desktop workspace directories — a filesystem path, so a disclosure question as much as a value one. |

**Beyond the per-key verdict this session must settle:** if `non-interactive` comes out of the
adoption denominators, that changes settled mart definitions (ADR-0008) and has to be said
out loud rather than implied. And promoting a `resource/*` key needs the parser to read the
resource block — check before assuming a flat `kind="attr"` row is enough.

### Group B — Ecosystem attribution: what Claude Code is being used *with*

**Axis:** MCP servers, plugins, skills and subagents compete for one answer — which parts of
the extension surface the fleet leans on, and which are installed and idle. Argued apart,
their readings contradict each other.

| Key | Records | Seats | Card | First-pass value case |
|---|---|---|---|---|
| `events` / `tool_decision` / **tool_source** *(unclassified)* | 45,244 | 18 | 3 | **The largest unclassified key in the window.** `builtin` 44,267/18 seats · `mcp` 964/5 seats · `sdk_host_builtin_mcp` 13. ~~The only direct measure of how much tool use is MCP rather than native.~~ **Corrected (#358):** the already-promoted `tool_name = 'mcp_tool'` is that measure — 1,027 rows both ways, `tool_source` adds 34 of 49,250 (0.07%). `kept`. |
| `metrics` / `claude_code.cost.usage` / **mcp_server.name**, **mcp_tool.name** *(unclassified)* | 1,780 each | 9 | 9 · 18 | A *second* cost-attribution path — `raw.events.api_request` already attributes $246.23 by server over the window. ~~Worth two columns only if the metrics path buys something the events path does not.~~ **Corrected (#358):** measured *exactly* redundant, not a grain question — 20 (server, tool) pairs both sides, 0 either-only, cost within 0.04%. `kept`. |
| `metrics` / `claude_code.token.usage` / **mcp_server.name**, **mcp_tool.name** | 7,120 each | 9 | 9 · 18 | Same fact on tokens; `kept` today. Promote with the cost pair or neither. |
| `events` / `mcp_server_connection` / **status**, **transport_type**, **server_scope**, **server_name**, **is_plugin**, **duration_ms** *(unclassified)*, **error_code** | 896 (error_code 2) | 13 | 2-24 | Which MCP servers connect, over which transport, how often they fail: `connected` 598 · `disconnected` 233 · `failed` 65/9 seats. `duration_ms` needs a registry row only — the column exists. |
| `events` / `tool_result` / **mcp_server_scope** | 980 | 9 | 4 | `dynamic` 777 · `project` 142 · `claudeai` 38 — where the MCP tool came from. |
| `events` / `subagent_completed` / **agent_type**, **agent.source**, **is_built_in**, **is_async**, **total_tokens**, **total_tool_uses**, **final_model** *(unclassified)* | 869 (final_model 794) | 12 | 2-76 | Which agents run, whether they are project-authored (`built-in` 840 vs `projectSettings` 29), and what each costs. `final_model` spans 7 models — `claude-sonnet-5` 482, `claude-opus-4-8[1m]` 171, `claude-haiku-4-5` 84. |
| `events` / `plugin_loaded` / **plugin.version**, **plugin.scope**, **has_hooks**, **has_mcp**, **skill_path_count**, **command_path_count**, **agent_path_count** | 1,475 (version 1,254) | 14 | 2-17 | Plugin inventory: `official` 916/10 seats vs `user-local` 559/12 seats. Loaded is not used — say which of these measures which. |
| `events` / `*` / **plugin_id_hash** | 2,497 | 14 | 35 | ~~Identifies a plugin that the promoted `plugin.name` does not name (details-gated).~~ **Corrected (#358):** `plugin.name` is present on **every** record carrying it, across all three events — zero exceptions. `kept`. |
| `events` / `skill_activated` / **invocation_trigger**, **skill.source** | 765 | 15 | 3 · 5 | `nested-skill` 320 · `user-slash` 278/12 seats · `claude-proactive` 167/13 seats — whether skills are pulled by the human or pushed by the model. |
| `events` / `plugin_installed` / **install.trigger**, **marketplace.is_official** | 5 | 4 | 1 | Five records in eleven days. Listed so the session closes it, not because it argues well. |

**Beyond the per-key verdict this session must settle:** the two reuse-or-add collisions #354
flagged — `subagent_completed.agent_type` against the existing `agent_name` column, and
`mcp_server_connection.server_name` against `mcp_server_name`.

### Group C — Cost, friction and reliability: how well the run goes

**Axis:** hook overhead, permission prompts, tool errors, retries and context pressure are one
question asked from different angles — what gets in the way — and they trade off against each
other, so a value case for one is only arguable next to the rest.

| Key | Records | Seats | Card | First-pass value case |
|---|---|---|---|---|
| `events` / `tool_result` / **decision_source** | 31,308 | 13 | 3 | `config` 30,746 · `user_temporary` 525 across **12 of 13 seats** · `user_permanent` 37. How often a human has to approve a tool by hand — a permission-friction reading the marts cannot produce today. |
| `events` / `hook_execution_complete` / **total_duration_ms**, **num_success**, **num_blocking**, **num_non_blocking_error**, **num_cancelled** | 31,362 | 18 | 2-500+ | Hook overhead per session, and hook failure rate. The three failure counters are non-zero on 34, 5 and 37 records of 31,362 — near-zero *is* the health signal, and also the weakest promotion case in the map. |
| `events` / `*` / **hook_source**, **num_hooks** | 64,884 · 62,722 | 18 | 5 · 4 | Where hooks come from (`merged` 62,722 · `projectSettings` 946 · `pluginHook` 936) and how many fire. Read with the counters above, not apart from them. |
| `events` / `hook_registered` / **hook_matcher** | 1,300 | 12 | 10 | Which events hooks bind to (`startup\|clear\|compact` 508 · `Bash` 233 · `Edit` 105) — the configuration behind the overhead. |
| `events` / `tool_result` / **error_type**, **tool_input_size_bytes**, **tool_result_size_bytes**, **tool_input** | 1,292 · 47,130 · 45,838 · 47,130 | 17-19 | 13 · 500+ | Failure taxonomy — `ShellError` 1,108 across 15 seats — plus payload sizing. `tool_input` is free text: decide it on disclosure, not fill. |
| `events` / `compaction` / **trigger**, **pre_tokens**, **post_tokens**, **duration_ms** *(unclassified)*, **precompute_reuse** | 54 (precompute_reuse 27) | 3 | 2-54 | Context pressure: how often sessions compact and how much they lose. Only **3 seats** in eleven days, so the volume verdict matters more than the value case. |
| `events` / `internal_error` / **error_name**, **error_code**; `events` / `*` / **attempt**, **status_code**; `api_retries_exhausted`, `api_refusal` | 79 · 2 · 29 · 24 · 3 · 1 | 1-11 | API reliability: `429` 13 and `529` 8 across 4 seats each. Low counts are the point of the reading, not evidence against it. |
| `events` / `feedback_survey` / **event_type**, **appearance_id** | 54 | 8 | 3 · 28 | A real funnel — `appeared` 28 · `abandoned` 21 · `responded` 5 — on a thin family. |
| `events` / `assistant_response` / **response_length**; `events` / `*` / **cost_usd_micros** | 21,976 · 43,286 | 20 | 500+ | Output sizing, and a units duplicate of the promoted `cost_usd`. |
| `events` / `*` / **client_request_id**; `assistant_response`,`user_prompt` / **message.uuid** *(unclassified)* | 41,698 · 21,038 · 2,113 | 18 | 500+ | Identifiers, not measures. Decide on join value only. |

## Settled by the evidence — no grilling needed

Seventeen keys hold **one value** across the whole window. Nothing is argued by putting a
constant in a column, so each stays `kept`; the three that have no registry row still need
one, which makes this a spec-row PR, not a no-op.

| Key | The single value | Records |
|---|---|---|
| `events` / `*` / **safe_mode** | `false` | 66,347 |
| `events` / `*` / **managed_only** | `false` | 62,722 |
| `events` / `tool_result` / **decision_type** | `accept` | 31,308 |
| `resource` / `*` / **host.arch** | `amd64` | 106,985 |
| `events` / `hook_registered` / **hook_type** | `command` | 2,162 |
| `events` / `plugin_loaded` / **enabled_via** | `user-install` | 1,475 |
| `events` / `plugin_loaded` / **host_owned_mcp** | `False` | 1,471 |
| `events` / `subagent_completed` / **model_swapped** *(unclassified)* | `False` | 794 |
| `events` / `feedback_survey` / **survey_type** | `session` | 54 |
| `events` / `feedback_survey` / **enabled_via_override** | `False` | 54 |
| `events` / `feedback_survey` / **event_origin** *(unclassified)* | `sdk_host` | 10 |
| `events` / `feedback_survey` / **event_origin_server** *(unclassified)* | `claude-vscode` | 10 |
| `events` / `auth` / **action** | `login` | 7 |
| `events` / `auth` / **auth_method** | `oauth` | 7 |
| `events` / `api_retries_exhausted` / **total_attempts** | `11` | 3 |
| `events` / `api_refusal` / **server_fallback_hop** | `True` | 1 |
| `events` / `skill_activated` / **skill.kind** | `workflow` | 1 |

`decision_type` is the one worth naming: `tool_result` only fires on an accepted tool, so the
reject side already lives in the promoted `decision` column on `tool_decision`. It is
redundant, not merely constant.

Two keys are *also* single-valued but are **not** settled — `resource/*/claude.deployment_mode`
(`1p`) and `resource/*/wsl.version` (`2`). For those the presence of the key is the signal, not
its value, so they stay in Group A.

Caveat: constant over eleven days and twenty seats is evidence, not a guarantee. A policy
change (managed settings, safe mode, a second auth method) would make several of these vary,
and a `kept` key does not resurface in `tools.sweep` once classified.

## Full evidence table

96 decision rows — every `kept` or `unclassified` key path in the window, collapsed to its
registry grain, excluding the resource-attribute duplicates, `process.owner` and
`event.timestamp`. `Fill` is the share of records of the key's own signal name; `Sess` and
`Seats` are the distinct sessions and seats the key reaches; `Card` is distinct values seen
(`+` means the 500-value cap was hit). In *Top values*, `/Ns` is the number of seats carrying
that value, shown only for keys with at most 25 distinct values.

| Key path | Status | Records | Fill | Sess | Seats | Card | Top values (count/seats) |
|---|---|---|---|---|---|---|---|
| `metrics` / `*` / **user.id** | kept | 243,676 | 100% | 691 | 20 | 53 | `02c1f29ee1210abfcf8d8281..` 88,268<br>`e08dcea65a6aff55fb50d99c..` 35,705<br>`229f5c2419b4246cfde1ce28..` 35,656 |
| `events` / `*` / **user.id** | kept | 232,050 | 100% | 676 | 20 | 52 | `02c1f29ee1210abfcf8d8281..` 72,334<br>`229f5c2419b4246cfde1ce28..` 53,478<br>`e08dcea65a6aff55fb50d99c..` 40,801 |
| `metrics` / `*` / **terminal.type** | kept | 219,208 | 90% | 657 | 19 | 4 | `windows-terminal` 144,165/8s<br>`non-interactive` 69,469/15s<br>`vscode` 4,438/5s |
| `events` / `*` / **terminal.type** | kept | 211,875 | 91% | 642 | 19 | 4 | `windows-terminal` 117,289/8s<br>`non-interactive` 90,126/15s<br>`vscode` 3,675/5s |
| `resource` / `*` / **service.name** | kept | 108,991 | 100% | 291 | 13 | 3 | `claude-code` 108,512/13s<br>`claude-code-desktop` 345<br>`cowork` 134 |
| `resource` / `*` / **host.arch** | kept | 106,985 | 98% | 0 | 0 | 1 | `amd64` 106,985 |
| `resource` / `*` / **os.type** | kept | 106,985 | 98% | 0 | 0 | 2 | `windows` 95,408<br>`linux` 11,577 |
| `resource` / `*` / **os.version** | kept | 106,985 | 98% | 0 | 0 | 2 | `10.0.26200` 95,408<br>`6.6.87.2-microsoft-stand..` 11,577 |
| `events` / `*` / **safe_mode** | kept | 66,347 | 100% | 615 | 18 | 1 | `false` 66,347/18s |
| `events` / `*` / **hook_source** | kept | 64,884 | 100% | 606 | 18 | 5 | `merged` 62,722/18s<br>`projectSettings` 946/6s<br>`pluginHook` 936/9s |
| `events` / `*` / **num_hooks** | kept | 62,722 | 100% | 599 | 18 | 4 | `1` 33,110/17s<br>`2` 21,528/12s<br>`3` 6,136/3s |
| `events` / `*` / **managed_only** | kept | 62,722 | 100% | 599 | 18 | 1 | `false` 62,722/18s |
| `events` / `tool_result` / **tool_input** | kept | 47,130 | 100% | 450 | 19 | 500+ | `{"todos":["<nested>","<n..` 53<br>`{"todos":["<nested>","<n..` 51<br>`{"todos":["<nested>","<n..` 43 |
| `events` / `tool_result` / **tool_input_size_bytes** | kept | 47,130 | 100% | 450 | 19 | 500+ | `37` 645<br>`122` 319<br>`94` 270 |
| `events` / `tool_result` / **tool_result_size_bytes** | kept | 45,838 | 97% | 449 | 19 | 500+ | `0` 480<br>`160` 451<br>`177` 251 |
| `events` / `tool_decision` / **tool_source** | **unclassified** | 45,244 | 96% | 438 | 18 | 3 | `builtin` 44,267/18s<br>`mcp` 964/5s<br>`sdk_host_builtin_mcp` 13/3s |
| `events` / `*` / **cost_usd_micros** | kept | 43,286 | 100% | 458 | 20 | 500+ | `15378` 4<br>`47074` 3<br>`52935` 3 |
| `events` / `*` / **client_request_id** | kept | 41,698 | 96% | 443 | 18 | 504+ | `2a8a4105-5ab5-4440-ae84-..` 1<br>`4c388ac8-3eff-4629-96b8-..` 1<br>`9636b826-2fa1-4402-a3d5-..` 1 |
| `events` / `hook_execution_complete` / **num_success** | kept | 31,362 | 100% | 597 | 18 | 5 | `1` 16,510/17s<br>`2` 10,755/12s<br>`3` 3,064/3s |
| `events` / `hook_execution_complete` / **num_blocking** | kept | 31,362 | 100% | 597 | 18 | 2 | `0` 31,328/18s<br>`1` 34/2s |
| `events` / `hook_execution_complete` / **num_non_blocking_error** | kept | 31,362 | 100% | 597 | 18 | 2 | `0` 31,357/18s<br>`1` 5/3s |
| `events` / `hook_execution_complete` / **num_cancelled** | kept | 31,362 | 100% | 597 | 18 | 2 | `0` 31,325/18s<br>`1` 37/2s |
| `events` / `hook_execution_complete` / **total_duration_ms** | kept | 31,362 | 100% | 597 | 18 | 500+ | `3` 397<br>`2` 332<br>`4` 288 |
| `events` / `tool_result` / **decision_source** | kept | 31,308 | 66% | 279 | 13 | 3 | `config` 30,746/13s<br>`user_temporary` 525/12s<br>`user_permanent` 37/5s |
| `events` / `tool_result` / **decision_type** | kept | 31,308 | 66% | 279 | 13 | 1 | `accept` 31,308/13s |
| `events` / `assistant_response` / **response_length** | kept | 21,976 | 100% | 457 | 20 | 500+ | `60` 139<br>`55` 138<br>`68` 133 |
| `events` / `tool_decision` / **tool_parameters** | **unclassified** | 21,610 | 46% | 416 | 18 | 500+ | `{"subagent_type":"genera..` 625<br>`{"subagent_type":"Explor..` 82<br>`{"skill_name":"superpowe..` 31 |
| `events` / `tool_result` / **tool_parameters** | **unclassified** | 21,545 | 46% | 416 | 17 | 500+ | `{"subagent_type":"genera..` 621<br>`{"subagent_type":"Explor..` 79<br>`{"skill_name":"superpowe..` 31 |
| `events` / `assistant_response` / **message.uuid** | **unclassified** | 21,038 | 96% | 443 | 18 | 500+ | `44f74f74-8798-44c7-8483-..` 1<br>`221ff9f6-e4ca-4c83-9994-..` 1<br>`29330e47-fb81-4e2e-9079-..` 1 |
| `resource` / `*` / **wsl.version** | kept | 11,577 | 11% | 0 | 0 | 1 | `2` 11,577 |
| `metrics` / `claude_code.token.usage` / **mcp_server.name** | kept | 7,120 | 5% | 40 | 9 | 9 | `custom` 4,356/3s<br>`claude_ai_Microsoft_Learn` 1,716/1s<br>`plugin_microsoft-docs_mi..` 640/1s |
| `metrics` / `claude_code.token.usage` / **mcp_tool.name** | kept | 7,120 | 5% | 40 | 9 | 18 | `custom` 4,356/3s<br>`microsoft_docs_search` 1,968/2s<br>`microsoft_docs_fetch` 388/2s |
| `events` / `*` / **plugin_id_hash** | kept | 2,497 | 55% | 380 | 14 | 35 | `a218113d2400f77d` 640<br>`46e51c00520427a5` 370<br>`d4546e5e29664056` 245 |
| `events` / `hook_registered` / **hook_type** | kept | 2,162 | 100% | 363 | 12 | 1 | `command` 2,162/12s |
| `events` / `user_prompt` / **message.uuid** | **unclassified** | 2,113 | 72% | 414 | 18 | 500+ | `b8666d37-4a10-4ab9-9e34-..` 1<br>`cb6870d1-b8aa-44be-b7d8-..` 1<br>`268a507f-844a-4ebc-ad05-..` 1 |
| `resource` / `*` / **user.email** | **unclassified** | 2,006 | 2% | 291 | 13 | 13 | `ahmed.gharib@itworx.com` 1,223/1s<br>`fadi.magdy@itworx.com` 214/1s<br>`kareem.elakkad@itworx.com` 179/1s |
| `resource` / `*` / **user.account_id** | **unclassified** | 2,006 | 2% | 291 | 13 | 13 | `eb72a4c2-a47e-4baa-880a-..` 1,223/1s<br>`92f1767e-6171-491c-8bae-..` 214/1s<br>`05d5c0b2-e7b3-43f5-8421-..` 179/1s |
| `resource` / `*` / **session.id** | **unclassified** | 2,006 | 2% | 291 | 13 | 291 | `44d09303-d0e8-4705-8e19-..` 63<br>`6359dccf-f167-4792-bf82-..` 57<br>`344d10c4-7e37-413d-b6c6-..` 52 |
| `metrics` / `claude_code.cost.usage` / **mcp_server.name** | **unclassified** | 1,780 | 5% | 40 | 9 | 9 | `custom` 1,089/3s<br>`claude_ai_Microsoft_Learn` 429/1s<br>`plugin_microsoft-docs_mi..` 160/1s |
| `metrics` / `claude_code.cost.usage` / **mcp_tool.name** | **unclassified** | 1,780 | 5% | 40 | 9 | 18 | `custom` 1,089/3s<br>`microsoft_docs_search` 492/2s<br>`microsoft_docs_fetch` 97/2s |
| `events` / `plugin_loaded` / **plugin.scope** | kept | 1,475 | 100% | 377 | 14 | 2 | `official` 916/10s<br>`user-local` 559/12s |
| `events` / `plugin_loaded` / **enabled_via** | kept | 1,475 | 100% | 377 | 14 | 1 | `user-install` 1,475/14s |
| `events` / `plugin_loaded` / **has_hooks** | kept | 1,475 | 100% | 377 | 14 | 2 | `False` 762/13s<br>`True` 713/9s |
| `events` / `plugin_loaded` / **has_mcp** | kept | 1,475 | 100% | 377 | 14 | 2 | `False` 1,237/14s<br>`True` 238/4s |
| `events` / `plugin_loaded` / **skill_path_count** | kept | 1,475 | 100% | 377 | 14 | 4 | `1` 1,285/13s<br>`0` 115/4s<br>`23` 61/1s |
| `events` / `plugin_loaded` / **command_path_count** | kept | 1,475 | 100% | 377 | 14 | 2 | `0` 1,285/14s<br>`1` 190/2s |
| `events` / `plugin_loaded` / **agent_path_count** | kept | 1,475 | 100% | 377 | 14 | 2 | `0` 1,266/14s<br>`1` 209/2s |
| `events` / `plugin_loaded` / **host_owned_mcp** | kept | 1,471 | 100% | 374 | 14 | 1 | `False` 1,471/14s |
| `events` / `hook_registered` / **hook_matcher** | kept | 1,300 | 60% | 352 | 12 | 10 | `startup\|clear\|compact` 508/9s<br>`Bash` 233/3s<br>`Edit` 105/1s |
| `events` / `tool_result` / **error_type** | kept | 1,292 | 3% | 275 | 17 | 13 | `ShellError` 1,108/15s<br>`TelemetrySafeError` 72/7s<br>`McpToolCallError` 66/6s |
| `events` / `plugin_loaded` / **plugin.version** | kept | 1,254 | 85% | 377 | 14 | 17 | `5.1.0` 389/2s<br>`1.0.0` 291/12s<br>`1.2.0` 142/2s |
| `events` / `tool_result` / **mcp_server_scope** | kept | 980 | 2% | 40 | 9 | 4 | `dynamic` 777/7s<br>`project` 142/1s<br>`claudeai` 38/3s |
| `events` / `mcp_server_connection` / **status** | kept | 896 | 100% | 212 | 13 | 3 | `connected` 598/13s<br>`disconnected` 233/6s<br>`failed` 65/9s |
| `events` / `mcp_server_connection` / **transport_type** | kept | 896 | 100% | 212 | 13 | 4 | `claudeai-proxy` 635/8s<br>`stdio` 197/9s<br>`ws-ide` 39/8s |
| `events` / `mcp_server_connection` / **server_scope** | kept | 896 | 100% | 212 | 13 | 5 | `claudeai` 635/8s<br>`dynamic` 126/11s<br>`project` 71/4s |
| `events` / `mcp_server_connection` / **duration_ms** | **unclassified** | 896 | 100% | 212 | 13 | 500+ | `11` 17<br>`9` 17<br>`12` 14 |
| `events` / `mcp_server_connection` / **is_plugin** | kept | 896 | 100% | 212 | 13 | 2 | `False` 810/12s<br>`True` 86/4s |
| `events` / `mcp_server_connection` / **server_name** | kept | 896 | 100% | 212 | 13 | 24 | `claude.ai Microsoft 365` 148/7s<br>`claude.ai Microsoft Learn` 133/5s<br>`claude.ai Exa` 105/1s |
| `events` / `subagent_completed` / **agent_type** | kept | 869 | 100% | 147 | 12 | 11 | `general-purpose` 726/10s<br>`Explore` 79/9s<br>`claude` 24/2s |
| `events` / `subagent_completed` / **agent.source** | kept | 869 | 100% | 147 | 12 | 2 | `built-in` 840/12s<br>`projectSettings` 29/4s |
| `events` / `subagent_completed` / **is_built_in** | kept | 869 | 100% | 147 | 12 | 2 | `True` 840/12s<br>`False` 29/4s |
| `events` / `subagent_completed` / **is_async** | kept | 869 | 100% | 147 | 12 | 2 | `False` 548/9s<br>`True` 321/10s |
| `events` / `subagent_completed` / **total_tokens** | kept | 869 | 100% | 147 | 12 | 500+ | `38179` 2<br>`34052` 2<br>`75136` 2 |
| `events` / `subagent_completed` / **total_tool_uses** | kept | 869 | 100% | 147 | 12 | 76 | `3` 52<br>`4` 51<br>`10` 46 |
| `events` / `subagent_completed` / **final_model** | **unclassified** | 794 | 91% | 143 | 11 | 7 | `claude-sonnet-5` 482/9s<br>`claude-opus-4-8[1m]` 171/9s<br>`claude-haiku-4-5-20251001` 84/6s |
| `events` / `subagent_completed` / **model_swapped** | **unclassified** | 794 | 91% | 143 | 11 | 1 | `False` 794/11s |
| `events` / `skill_activated` / **invocation_trigger** | kept | 765 | 100% | 293 | 15 | 3 | `nested-skill` 320/7s<br>`user-slash` 278/12s<br>`claude-proactive` 167/13s |
| `events` / `skill_activated` / **skill.source** | kept | 765 | 100% | 293 | 15 | 5 | `userSettings` 359/5s<br>`projectSettings` 203/9s<br>`plugin` 178/9s |
| `resource` / `*` / **claude.deployment_mode** | kept | 479 | 0% | 0 | 0 | 1 | `1p` 479 |
| `events` / `*` / **workflow.run_id** | kept | 216 | 0% | 1 | 1 | 1 | `wf_151ddb72-d5e` 216/1s |
| `events` / `*` / **workflow.name** | kept | 216 | 0% | 1 | 1 | 1 | `databricks-q-scoring` 216/1s |
| `events` / `*` / **workspace.host_paths** | kept | 110 | 0% | 4 | 1 | 3 | `{'arrayValue': {'values'..` 69/1s<br>`{'arrayValue': {'values'..` 26/1s<br>`{'arrayValue': {'values'..` 15/1s |
| `events` / `internal_error` / **error_name** | kept | 79 | 100% | 75 | 11 | 3 | `TelemetrySafeError` 73/10s<br>`Error` 4/2s<br>`ZPr` 2/1s |
| `events` / `feedback_survey` / **event_type** | kept | 54 | 100% | 31 | 8 | 3 | `appeared` 28/8s<br>`abandoned` 21/5s<br>`responded` 5/4s |
| `events` / `feedback_survey` / **appearance_id** | kept | 54 | 100% | 31 | 8 | 28 | `9cba0934-11fb-44a8-9b1d-..` 2<br>`c33cac66-6adb-4d39-9743-..` 2<br>`ee8e9925-7b91-4b76-ae8c-..` 2 |
| `events` / `feedback_survey` / **survey_type** | kept | 54 | 100% | 31 | 8 | 1 | `session` 54/8s |
| `events` / `feedback_survey` / **enabled_via_override** | kept | 54 | 100% | 31 | 8 | 1 | `False` 54/8s |
| `events` / `compaction` / **trigger** | kept | 54 | 100% | 39 | 3 | 2 | `manual` 27/3s<br>`auto` 27/1s |
| `events` / `compaction` / **duration_ms** | **unclassified** | 54 | 100% | 39 | 3 | 54 | `103067` 1<br>`126290` 1<br>`102170` 1 |
| `events` / `compaction` / **pre_tokens** | kept | 54 | 100% | 39 | 3 | 54 | `187658` 1<br>`87069` 1<br>`46410` 1 |
| `events` / `compaction` / **post_tokens** | kept | 54 | 100% | 39 | 3 | 54 | `28292` 1<br>`25944` 1<br>`9426` 1 |
| `events` / `*` / **attempt** | kept | 29 | 100% | 17 | 8 | 3 | `1` 21/5s<br>`0` 5/3s<br>`11` 3/3s |
| `events` / `compaction` / **precompute_reuse** | kept | 27 | 50% | 18 | 3 | 3 | `miss_not_ready` 14/3s<br>`miss_hook` 8/1s<br>`miss_custom_instructions` 5/3s |
| `events` / `*` / **status_code** | kept | 24 | 77% | 12 | 6 | 4 | `429` 13/4s<br>`529` 8/4s<br>`500` 2/1s |
| `events` / `feedback_survey` / **event_origin** | **unclassified** | 10 | 19% | 6 | 3 | 1 | `sdk_host` 10/3s |
| `events` / `feedback_survey` / **event_origin_server** | **unclassified** | 10 | 19% | 6 | 3 | 1 | `claude-vscode` 10/3s |
| `events` / `auth` / **action** | kept | 7 | 100% | 7 | 7 | 1 | `login` 7/7s |
| `events` / `auth` / **auth_method** | kept | 7 | 100% | 7 | 7 | 1 | `oauth` 7/7s |
| `events` / `plugin_installed` / **marketplace.is_official** | kept | 5 | 100% | 5 | 4 | 1 | `true` 5/4s |
| `events` / `plugin_installed` / **install.trigger** | kept | 5 | 100% | 5 | 4 | 1 | `ui` 5/4s |
| `events` / `api_retries_exhausted` / **total_attempts** | kept | 3 | 100% | 3 | 3 | 1 | `11` 3/3s |
| `events` / `api_retries_exhausted` / **total_retry_duration_ms** | kept | 3 | 100% | 3 | 3 | 3 | `205053` 1/1s<br>`209509` 1/1s<br>`233832` 1/1s |
| `events` / `mcp_server_connection` / **error_code** | kept | 2 | 0% | 2 | 2 | 2 | `-32000` 1/1s<br>`EUNKNOWN` 1/1s |
| `events` / `internal_error` / **error_code** | kept | 2 | 3% | 2 | 1 | 1 | `EPERM` 2/1s |
| `events` / `skill_activated` / **skill.kind** | kept | 1 | 0% | 1 | 1 | 1 | `workflow` 1/1s |
| `events` / `api_refusal` / **server_fallback_hop** | kept | 1 | 100% | 1 | 1 | 1 | `True` 1/1s |
