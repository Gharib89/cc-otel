"""The authoritative attr -> column -> status catalogue (#167).

One fact per row — "attribute X becomes column Y of type Z with status
promoted/kept/denied" — recorded once here and derived everywhere else. This
module is the single source of truth previously hand-synced across four copies
(parser maps, store column tuples, raw DDL, the ``meta.column_registry`` seed)
plus the redaction denylist. ``meta.column_registry`` is its *deployed
projection*; ``tools.spec_sync`` proves the two converge.

Data-only: no I/O, no imports beyond stdlib typing. Consumers derive their
constants at import time via the pure functions below; the invariants run once
at import (i.e. in every unit-test run), so a malformed row fails fast.

``kind`` records how a promoted column is populated by the sink:

* ``attr``       — flat ``attr -> column`` map (``parser.*_ATTR_COLUMNS``).
* ``structural`` — read from OTLP structure (timestamps, scope, metric value),
  never from the attribute map.
* ``derived``    — ordered coalesce over several attr paths (first truthy value
  wins), driven by ``derived_coalesce`` (``user_account_id``, ``cc_version``).

``deny_mode`` records how a denied key is stripped by ``redaction``:

* ``strip``            — removed from every attribute list wherever it appears.
* ``defense_in_depth`` — content key a client gate already suppresses; a
  non-empty hit is counted as gate drift.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

Signal = Literal["metrics", "events", "resource"]
Status = Literal["promoted", "kept", "denied"]
Kind = Literal["attr", "structural", "derived"]
DataType = Literal[
    "TEXT",
    "UUID",
    "TIMESTAMPTZ",
    "BIGINT",
    "INTEGER",
    "SMALLINT",
    "DOUBLE PRECISION",
    "BOOLEAN",
]
DenyMode = Literal["strip", "defense_in_depth"]

_INT_TYPES: frozenset[str] = frozenset({"BIGINT", "INTEGER", "SMALLINT"})


@dataclass(frozen=True, slots=True)
class ColumnSpec:
    signal: Signal
    signal_name: str  # '*' or the metric/event name (registry grain)
    attr_path: str  # raw OTLP key, or the structural pseudo-path
    status: Status
    column_name: str | None = None  # promoted only
    data_type: DataType | None = None
    kind: Kind = "attr"  # how a promoted column is populated (see module docstring)
    deny_mode: DenyMode | None = None  # denied only
    description: str = ""
    useful_for: str | None = None
    decided_at: str = ""  # ISO date
    notes: str | None = None


COLUMN_SPEC: tuple[ColumnSpec, ...] = (
    # ===== metrics: promoted =====
    ColumnSpec(
        "metrics",
        "*",
        "timeUnixNano",
        "promoted",
        "ts",
        "TIMESTAMPTZ",
        "structural",
        description="Metric data-point timestamp.",
        useful_for="time grain",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "metric.name",
        "promoted",
        "metric_name",
        "TEXT",
        "structural",
        description="OTel instrument name.",
        useful_for="signal routing",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "metric.type",
        "promoted",
        "metric_type",
        "TEXT",
        "structural",
        description="Instrument kind: gauge/sum/histogram.",
        useful_for="temporality handling",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "dataPoint.value",
        "promoted",
        "value",
        "DOUBLE PRECISION",
        "structural",
        description="Numeric data-point value (delta counters).",
        useful_for="all measures",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "dataPoint.count",
        "promoted",
        "count",
        "BIGINT",
        "structural",
        description="Pre-aggregated count on histogram instruments.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "dataPoint.value_kind",
        "promoted",
        "value_kind",
        "TEXT",
        "structural",
        description="Derived: gauge_last/sum_delta/sum_cumulative/hist_sum.",
        useful_for="delta-only staging filter",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "scope.name",
        "promoted",
        "scope_name",
        "TEXT",
        "structural",
        description="OTel instrumentation scope.",
        useful_for="wrapper-vs-native split",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "scope.version",
        "promoted",
        "scope_version",
        "TEXT",
        "structural",
        description="Instrumentation scope version.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "session.id",
        "promoted",
        "session_id",
        "UUID",
        description="Claude Code session UUID.",
        useful_for="session facts",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "user.email",
        "promoted",
        "user_email",
        "TEXT",
        description="Developer identity (normalized lowercase/trim).",
        useful_for="dim_user join",
        decided_at="2026-07-13",
        notes="identity kept per #6",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "process.owner",
        "promoted",
        "process_owner",
        "TEXT",
        description="OS account the Claude Code process runs under (e.g. a Windows username).",
        useful_for="account sharing: a row whose process_owner disagrees with user_email is "
        "one person emitting under another person's account",
        decided_at="2026-07-28",
        notes="promoted, not denied: discloses strictly less than the promoted user.email (#353)",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "user.account_uuid",
        "promoted",
        "user_account_id",
        "TEXT",
        "derived",
        description="Anthropic account UUID.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "user.account_id",
        "promoted",
        "user_account_id",
        "TEXT",
        "derived",
        description="Anthropic tagged account id.",
        decided_at="2026-07-13",
        notes="coalesced into user_account_id under user.account_uuid",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "organization.id",
        "promoted",
        "organization_id",
        "TEXT",
        description="Organization UUID.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "model",
        "promoted",
        "model",
        "TEXT",
        description="Model id (usage/cost/LOC metrics).",
        useful_for="dim_model",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "app.version",
        "promoted",
        "cc_version",
        "TEXT",
        "derived",
        description="Claude Code version.",
        useful_for="install health",
        decided_at="2026-07-13",
        notes="coalesced over resource service.version",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "query_source",
        "promoted",
        "query_source",
        "TEXT",
        description="Request origin: main/subagent/auxiliary.",
        decided_at="2026-07-13",
        notes="on token.usage/cost.usage",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "effort",
        "promoted",
        "effort",
        "TEXT",
        description="Reasoning-effort level.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "speed",
        "promoted",
        "speed",
        "TEXT",
        description="fast when fast-mode.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "agent.name",
        "promoted",
        "agent_name",
        "TEXT",
        description="Agent attribution (custom collapses).",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "skill.name",
        "promoted",
        "skill_name",
        "TEXT",
        description="Skill attribution.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "plugin.name",
        "promoted",
        "plugin_name",
        "TEXT",
        description="Plugin attribution.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "marketplace.name",
        "promoted",
        "marketplace_name",
        "TEXT",
        description="Marketplace attribution.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "claude_code.token.usage",
        "type",
        "promoted",
        "type_label",
        "TEXT",
        description="Token type: input/output/cacheRead/cacheCreation.",
        useful_for="token breakdown",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "claude_code.active_time.total",
        "type",
        "promoted",
        "type_label",
        "TEXT",
        description="Active-time type: user (keyboard) / cli (tools+AI).",
        useful_for="active time split",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "claude_code.lines_of_code.count",
        "type",
        "promoted",
        "type_label",
        "TEXT",
        description="LOC change type: added / removed.",
        useful_for="loc measures",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "claude_code.code_edit_tool.decision",
        "tool_name",
        "promoted",
        "tool_name",
        "TEXT",
        description="Edit/Write/NotebookEdit.",
        useful_for="fact_edit_decision",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "claude_code.code_edit_tool.decision",
        "decision",
        "promoted",
        "decision",
        "TEXT",
        description="accept / reject.",
        useful_for="acceptance rate",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "claude_code.code_edit_tool.decision",
        "source",
        "promoted",
        "source",
        "TEXT",
        description="Decision source: config/hook/user_*.",
        useful_for="auto-vs-human split",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "claude_code.code_edit_tool.decision",
        "language",
        "promoted",
        "language",
        "TEXT",
        description="Detected language.",
        useful_for="language mix",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "claude_code.session.count",
        "start_type",
        "promoted",
        "start_type",
        "TEXT",
        description="fresh/resume/continue/agents_view.",
        useful_for="fact_session",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "claude_code.usage.utilization",
        "window",
        "promoted",
        "usage_window",
        "TEXT",
        description="Rate-limit window (5h/7d/...).",
        useful_for="fact_usage_window",
        decided_at="2026-07-13",
        notes="wrapper telemetry (ADR-0003)",
    ),
    ColumnSpec(
        "metrics",
        "claude_code.usage.reset_in_seconds",
        "window",
        "promoted",
        "usage_window",
        "TEXT",
        description="Rate-limit window (5h/7d/...).",
        useful_for="fact_usage_window",
        decided_at="2026-07-13",
        notes="wrapper telemetry (ADR-0003)",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "terminal.type",
        "promoted",
        "terminal_type",
        "TEXT",
        description="Terminal app type (terminal / VS Code / non-interactive).",
        useful_for="surface split; non-interactive is adoption, not noise",
        decided_at="2026-07-29",
        notes="promoted from kept (#357): 15 of 19 seats run non-interactive",
    ),
    # ===== metrics: kept (blob-only) =====
    ColumnSpec(
        "metrics",
        "*",
        "user.id",
        "kept",
        description="Anonymous install id.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics", "*", "host.name", "kept", description="Hostname.", decided_at="2026-07-13"
    ),
    ColumnSpec(
        "metrics",
        "*",
        "app.entrypoint",
        "kept",
        description="Launch surface (opt-in).",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "context_window_size",
        "kept",
        description="Context window size.",
        decided_at="2026-07-13",
        notes="wrapper telemetry",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "fast_mode",
        "kept",
        description="Fast-mode flag.",
        decided_at="2026-07-13",
        notes="wrapper telemetry",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "thinking_enabled",
        "kept",
        description="Thinking-enabled flag.",
        decided_at="2026-07-13",
        notes="wrapper telemetry",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "output_style",
        "kept",
        description="Output style.",
        decided_at="2026-07-13",
        notes="wrapper telemetry",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "repo.owner",
        "kept",
        description="Repo owner.",
        decided_at="2026-07-13",
        notes="wrapper telemetry",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "repo.name",
        "kept",
        description="Repo name.",
        decided_at="2026-07-13",
        notes="wrapper telemetry",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "session_name",
        "kept",
        description="Session label.",
        decided_at="2026-07-13",
        notes="wrapper telemetry",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "workspace.host_paths",
        "kept",
        description="Desktop workspace dirs.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "metrics",
        "claude_code.token.usage",
        "mcp_server.name",
        "kept",
        description="MCP server attribution.",
        decided_at="2026-07-13",
        notes="not promoted on metrics; api_request carries it for bridges",
    ),
    ColumnSpec(
        "metrics",
        "claude_code.token.usage",
        "mcp_tool.name",
        "kept",
        description="MCP tool attribution.",
        decided_at="2026-07-13",
        notes="not promoted on metrics",
    ),
    ColumnSpec(
        "metrics",
        "claude_code.cost.usage",
        "mcp_server.name",
        "kept",
        description="MCP server attribution.",
        decided_at="2026-07-29",
        notes="kept basis collinear (#358): exactly redundant with raw.events.api_request -- "
        "20 (server, tool) pairs both sides, 0 either-only, cost within 0.04%",
    ),
    ColumnSpec(
        "metrics",
        "claude_code.cost.usage",
        "mcp_tool.name",
        "kept",
        description="MCP tool attribution.",
        decided_at="2026-07-29",
        notes="kept basis collinear (#358): same pair; promoting would mint a second, ambiguous "
        "MCP-cost path (ADR-0008)",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "gen_ai.operation.name",
        "kept",
        description="GenAI operation.",
        decided_at="2026-07-13",
        notes="non-Claude-Code (GitHub Copilot); not modeled",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "gen_ai.provider.name",
        "kept",
        description="GenAI provider.",
        decided_at="2026-07-13",
        notes="non-Claude-Code (GitHub Copilot); not modeled",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "gen_ai.request.model",
        "kept",
        description="GenAI request model.",
        decided_at="2026-07-13",
        notes="non-Claude-Code (GitHub Copilot); not modeled",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "gen_ai.response.model",
        "kept",
        description="GenAI response model.",
        decided_at="2026-07-13",
        notes="non-Claude-Code (GitHub Copilot); not modeled",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "gen_ai.tool.name",
        "kept",
        description="GenAI tool.",
        decided_at="2026-07-13",
        notes="non-Claude-Code (GitHub Copilot); not modeled",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "gen_ai.token.type",
        "kept",
        description="GenAI token type.",
        decided_at="2026-07-13",
        notes="non-Claude-Code (GitHub Copilot); not modeled",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "outcome",
        "kept",
        description="Connection outcome.",
        decided_at="2026-07-13",
        notes="non-Claude-Code (GitHub Copilot); not modeled",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "transport",
        "kept",
        description="Transport.",
        decided_at="2026-07-13",
        notes="non-Claude-Code (GitHub Copilot); not modeled",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "error.type",
        "kept",
        description="Error type enum.",
        decided_at="2026-07-13",
        notes="non-Claude-Code (GitHub Copilot); not modeled",
    ),
    # ===== resource attrs (all signals) =====
    #
    # The three identity rows below (session.id, user.email, user.account_id) record
    # the ADR-0003 wrapper contract: a wrapper
    # may put identity on the *resource* block rather than the data point, and the
    # sink reads it through the same merge. Without them the sweep's
    # one-directional resource/* fallback still reads them unclassified at the
    # resource path (#353).
    #
    # A promoted row here owns its column on *both* raw tables (``promoted_columns``);
    # the identity rows below merely mirror a column an own-signal row already
    # declares, while service.name and os.type are resource-only and reach the DDL
    # through this projection alone (#357).
    ColumnSpec(
        "resource",
        "*",
        "session.id",
        "promoted",
        "session_id",
        "UUID",
        description="Claude Code session UUID.",
        useful_for="session facts",
        decided_at="2026-07-28",
        notes="ADR-0003 wrapper contract: identity on the resource block",
    ),
    ColumnSpec(
        "resource",
        "*",
        "user.email",
        "promoted",
        "user_email",
        "TEXT",
        description="Developer identity (normalized lowercase/trim).",
        useful_for="dim_user join",
        decided_at="2026-07-28",
        notes="ADR-0003 wrapper contract: identity on the resource block",
    ),
    ColumnSpec(
        "resource",
        "*",
        "user.account_id",
        "promoted",
        "user_account_id",
        "TEXT",
        "derived",
        description="Anthropic tagged account id.",
        decided_at="2026-07-28",
        notes="ADR-0003 wrapper contract; coalesced into user_account_id under user.account_uuid",
    ),
    ColumnSpec(
        "resource",
        "*",
        "process.owner",
        "promoted",
        "process_owner",
        "TEXT",
        description="OS account the Claude Code process runs under (e.g. a Windows username).",
        useful_for="account sharing: a row whose process_owner disagrees with user_email is "
        "one person emitting under another person's account",
        decided_at="2026-07-28",
        notes="promoted, not denied: discloses strictly less than the promoted user.email (#353)",
    ),
    ColumnSpec(
        "resource",
        "*",
        "service.name",
        "promoted",
        "service_name",
        "TEXT",
        "derived",
        description="Emitting surface: claude-code / claude-code-desktop / cowork.",
        useful_for="desktop adoption; the only key separating the three surfaces",
        decided_at="2026-07-29",
        notes="promoted from kept (#357); resource-only, so kind=derived reaches both raw tables",
    ),
    ColumnSpec(
        "resource",
        "*",
        "service.version",
        "promoted",
        "cc_version",
        "TEXT",
        "derived",
        description="Claude Code version.",
        useful_for="install health",
        decided_at="2026-07-13",
        notes="coalesced under attrs app.version",
    ),
    ColumnSpec(
        "resource",
        "*",
        "os.type",
        "promoted",
        "os_type",
        "TEXT",
        "derived",
        description="OS type; carries the WSL-vs-native-Windows split on its own.",
        useful_for="fleet composition figure",
        decided_at="2026-07-29",
        notes="promoted from kept (#357); wsl.version is exactly collinear with os_type='linux'",
    ),
    ColumnSpec(
        "resource", "*", "os.version", "kept", description="OS version.", decided_at="2026-07-13"
    ),
    ColumnSpec(
        "resource",
        "*",
        "host.arch",
        "kept",
        description="Host architecture.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "resource", "*", "wsl.version", "kept", description="WSL version.", decided_at="2026-07-13"
    ),
    ColumnSpec(
        "resource",
        "*",
        "claude.deployment_mode",
        "kept",
        description="Deployment mode (e.g. 1p test rows).",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "resource",
        "*",
        "department",
        "kept",
        description="Org department (OTEL_RESOURCE_ATTRIBUTES).",
        decided_at="2026-07-13",
        notes="org dims come from Azure SQL (#9), not the pipeline",
    ),
    ColumnSpec(
        "resource",
        "*",
        "region",
        "kept",
        description="Org region.",
        decided_at="2026-07-13",
        notes="org dims come from Azure SQL (#9)",
    ),
    ColumnSpec(
        "resource",
        "*",
        "cost_center",
        "kept",
        description="Org cost center.",
        decided_at="2026-07-13",
        notes="org dims come from Azure SQL (#9)",
    ),
    ColumnSpec(
        "resource",
        "*",
        "company",
        "kept",
        description="Org company.",
        decided_at="2026-07-13",
        notes="org dims come from Azure SQL (#9)",
    ),
    ColumnSpec(
        "resource",
        "*",
        "team",
        "kept",
        description="Org team.",
        decided_at="2026-07-13",
        notes="org dims come from Azure SQL (#9)",
    ),
    # ===== events: promoted =====
    ColumnSpec(
        "events",
        "*",
        "timeUnixNano",
        "promoted",
        "event_time",
        "TIMESTAMPTZ",
        "structural",
        description="Log-record timestamp.",
        useful_for="time grain",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "event.name",
        "promoted",
        "event_name",
        "TEXT",
        "structural",
        description="Event name.",
        useful_for="signal routing",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "severityText",
        "promoted",
        "severity",
        "TEXT",
        "structural",
        description="Log severity text.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "logRecord.body",
        "promoted",
        "body",
        "TEXT",
        "structural",
        description="OTLP log-record body (event-name string for CC events).",
        decided_at="2026-07-13",
        notes="the log-record body field, not the `body` attribute on api_*_body events (denied)",
    ),
    ColumnSpec(
        "events",
        "*",
        "severityNumber",
        "promoted",
        "severity_number",
        "SMALLINT",
        "structural",
        description="Log severity number.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "traceId",
        "promoted",
        "log_trace_id",
        "TEXT",
        "structural",
        description="Trace id if present.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "spanId",
        "promoted",
        "log_span_id",
        "TEXT",
        "structural",
        description="Span id if present.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "droppedAttributesCount",
        "promoted",
        "dropped_attributes_count",
        "INTEGER",
        "structural",
        description="Dropped-attribute count.",
        useful_for="ingest QA",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "scope.name",
        "promoted",
        "scope_name",
        "TEXT",
        "structural",
        description="Instrumentation scope.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "scope.version",
        "promoted",
        "scope_version",
        "TEXT",
        "structural",
        description="Scope version.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "session.id",
        "promoted",
        "session_id",
        "UUID",
        description="Claude Code session UUID.",
        useful_for="session facts",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "prompt.id",
        "promoted",
        "prompt_id",
        "UUID",
        description="Prompt UUID.",
        useful_for="prompt correlation",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "user.email",
        "promoted",
        "user_email",
        "TEXT",
        description="Developer identity (normalized lowercase/trim).",
        useful_for="dim_user join",
        decided_at="2026-07-13",
        notes="identity kept per #6",
    ),
    ColumnSpec(
        "events",
        "*",
        "process.owner",
        "promoted",
        "process_owner",
        "TEXT",
        description="OS account the Claude Code process runs under (e.g. a Windows username).",
        useful_for="account sharing: a row whose process_owner disagrees with user_email is "
        "one person emitting under another person's account",
        decided_at="2026-07-28",
        notes="promoted, not denied: discloses strictly less than the promoted user.email (#353)",
    ),
    ColumnSpec(
        "events",
        "*",
        "user.account_uuid",
        "promoted",
        "user_account_id",
        "TEXT",
        "derived",
        description="Anthropic account UUID.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "user.account_id",
        "promoted",
        "user_account_id",
        "TEXT",
        "derived",
        description="Anthropic tagged account id.",
        decided_at="2026-07-13",
        notes="coalesced into user_account_id under user.account_uuid",
    ),
    ColumnSpec(
        "events",
        "*",
        "organization.id",
        "promoted",
        "organization_id",
        "TEXT",
        description="Organization UUID.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "app.version",
        "promoted",
        "cc_version",
        "TEXT",
        "derived",
        description="Claude Code version.",
        useful_for="install health",
        decided_at="2026-07-13",
        notes="coalesced over resource service.version",
    ),
    ColumnSpec(
        "events",
        "*",
        "event.sequence",
        "promoted",
        "event_sequence",
        "BIGINT",
        description="Per-session event ordinal.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "model",
        "promoted",
        "model",
        "TEXT",
        description="Model id (api_request/assistant_response).",
        useful_for="fact_api_usage",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "request_id",
        "promoted",
        "request_id",
        "TEXT",
        description="Anthropic API request id.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "speed",
        "promoted",
        "speed",
        "TEXT",
        description="fast/normal.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "effort",
        "promoted",
        "effort",
        "TEXT",
        description="Reasoning-effort level.",
        useful_for="fact_api_usage",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "query_source",
        "promoted",
        "query_source",
        "TEXT",
        description="Request origin.",
        useful_for="fact_api_usage",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "skill.name",
        "promoted",
        "skill_name",
        "TEXT",
        description="Skill name (skill_activated/api_request).",
        useful_for="bridge_session_skill",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "agent.name",
        "promoted",
        "agent_name",
        "TEXT",
        description="Agent attribution (api_request).",
        useful_for="bridge_session_agent",
        decided_at="2026-07-13",
        notes="schema-v2 add",
    ),
    ColumnSpec(
        "events",
        "*",
        "plugin.name",
        "promoted",
        "plugin_name",
        "TEXT",
        description="Plugin name (plugin_loaded).",
        useful_for="bridge_session_plugin",
        decided_at="2026-07-13",
        notes="schema-v2 add",
    ),
    ColumnSpec(
        "events",
        "*",
        "marketplace.name",
        "promoted",
        "marketplace_name",
        "TEXT",
        description="Marketplace attribution.",
        decided_at="2026-07-13",
        notes="schema-v2 add",
    ),
    ColumnSpec(
        "events",
        "*",
        "mcp_server.name",
        "promoted",
        "mcp_server_name",
        "TEXT",
        description="MCP server attribution (api_request).",
        useful_for="bridge_session_mcp",
        decided_at="2026-07-13",
        notes="schema-v2 add",
    ),
    ColumnSpec(
        "events",
        "*",
        "mcp_tool.name",
        "promoted",
        "mcp_tool_name",
        "TEXT",
        description="MCP tool attribution (api_request).",
        decided_at="2026-07-13",
        notes="schema-v2 add",
    ),
    ColumnSpec(
        "events",
        "*",
        "tool_name",
        "promoted",
        "tool_name",
        "TEXT",
        description="Tool name (tool_decision/tool_result; incl. mcp__*).",
        useful_for="bridge_session_mcp",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "tool_use_id",
        "promoted",
        "tool_use_id",
        "TEXT",
        description="Tool invocation id.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "decision",
        "promoted",
        "decision",
        "TEXT",
        description="accept / reject (tool_decision).",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "source",
        "promoted",
        "source",
        "TEXT",
        description="Decision source (tool_decision).",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "success",
        "promoted",
        "success_bool",
        "BOOLEAN",
        description="Success flag where reported.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "hook_name",
        "promoted",
        "hook_name",
        "TEXT",
        description="Hook name (hook_execution_*/hook_registered).",
        useful_for="bridge_session_hook",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "hook_event",
        "promoted",
        "hook_event",
        "TEXT",
        description="Hook trigger event.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "api_request",
        "input_tokens",
        "promoted",
        "input_tokens",
        "BIGINT",
        description="Prompt tokens.",
        useful_for="fact_api_usage",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "api_request",
        "output_tokens",
        "promoted",
        "output_tokens",
        "BIGINT",
        description="Completion tokens.",
        useful_for="fact_api_usage",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "api_request",
        "cache_creation_tokens",
        "promoted",
        "cache_creation_tokens",
        "BIGINT",
        description="Cache-write tokens.",
        useful_for="fact_api_usage",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "api_request",
        "cache_read_tokens",
        "promoted",
        "cache_read_tokens",
        "BIGINT",
        description="Cache-read tokens.",
        useful_for="fact_api_usage",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "api_request",
        "cost_usd",
        "promoted",
        "cost_usd",
        "DOUBLE PRECISION",
        description="Estimated cost.",
        decided_at="2026-07-13",
        notes="archived; marts are adoption-only (no cost)",
    ),
    ColumnSpec(
        "events",
        "api_request",
        "duration_ms",
        "promoted",
        "duration_ms",
        "BIGINT",
        description="API request duration.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "api_error",
        "duration_ms",
        "promoted",
        "duration_ms",
        "BIGINT",
        description="Failed request duration.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "tool_result",
        "duration_ms",
        "promoted",
        "duration_ms",
        "BIGINT",
        description="Tool execution duration.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "subagent_completed",
        "duration_ms",
        "promoted",
        "duration_ms",
        "BIGINT",
        description="Subagent duration.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "mcp_server_connection",
        "duration_ms",
        "promoted",
        "duration_ms",
        "BIGINT",
        description="MCP server connection duration.",
        decided_at="2026-07-28",
        notes="already stored: 1,164 rows 100% populated before the row existed (#353)",
    ),
    ColumnSpec(
        "events",
        "compaction",
        "duration_ms",
        "promoted",
        "duration_ms",
        "BIGINT",
        description="Compaction duration.",
        decided_at="2026-07-28",
        notes="already stored: 56 rows 100% populated before the row existed (#353)",
    ),
    ColumnSpec(
        "events",
        "user_prompt",
        "prompt_length",
        "promoted",
        "prompt_length",
        "BIGINT",
        description="Prompt length in chars.",
        useful_for="non-empty session",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "user_prompt",
        "command_name",
        "promoted",
        "command_name",
        "TEXT",
        description="Slash-command name.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "user_prompt",
        "command_source",
        "promoted",
        "command_source",
        "TEXT",
        description="builtin/custom/mcp.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "permission_mode_changed",
        "from_mode",
        "promoted",
        "from_mode",
        "TEXT",
        description="Permission mode before change.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "permission_mode_changed",
        "to_mode",
        "promoted",
        "to_mode",
        "TEXT",
        description="Permission mode after change.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "permission_mode_changed",
        "trigger",
        "promoted",
        "trigger",
        "TEXT",
        description="Mode-change trigger.",
        decided_at="2026-07-13",
    ),
    # raw.events.trigger is polysemous — shift_tab/auto_gate_denied/exit_plan_mode
    # from permission_mode_changed, manual/auto from compaction. Not colliding, and
    # the per-signal_name grain is what documents the two meanings.
    ColumnSpec(
        "events",
        "compaction",
        "trigger",
        "promoted",
        "trigger",
        "TEXT",
        description="Compaction trigger (auto/manual).",
        decided_at="2026-07-28",
        notes="promoted from kept: raw.events.trigger already carried 57 compaction rows (#353)",
    ),
    ColumnSpec(
        "events",
        "at_mention",
        "mention_type",
        "promoted",
        "mention_type",
        "TEXT",
        description="@-mention target type.",
        decided_at="2026-07-13",
    ),
    # The rows below are the #350 curation pass's kept -> promoted flips (#357 / #358 /
    # #359), all kind="attr" (no parser edit). Density posture and the
    # one-attr-path-per-column rule: #354. They stay in this section rather than opening
    # a per-PR one — the sections partition by signal and status, and each row already
    # carries its own provenance in decided_at/notes.
    ColumnSpec(
        "events",
        "*",
        "terminal.type",
        "promoted",
        "terminal_type",
        "TEXT",
        description="Terminal app type (terminal / VS Code / non-interactive).",
        useful_for="surface split; non-interactive is adoption, not noise",
        decided_at="2026-07-29",
        notes="promoted from kept (#357): 15 of 19 seats run non-interactive",
    ),
    ColumnSpec(
        "events",
        "*",
        "workflow.name",
        "promoted",
        "workflow_name",
        "TEXT",
        description="Workflow name on workflow-spawned agents.",
        useful_for="dynamic-workflow adoption (a figure, not a slicer)",
        decided_at="2026-07-29",
        notes="promoted from kept (#357); workflow.run_id stays kept as "
        "high-cardinality run identity",
    ),
    ColumnSpec(
        "events",
        "mcp_server_connection",
        "server_name",
        "promoted",
        "mcp_connection_server_name",
        "TEXT",
        description="MCP server display name on the connection event.",
        useful_for="installed-and-idle MCP servers: ~25 connect, 8 are ever paid for",
        decided_at="2026-07-29",
        notes="promoted from kept (#358); a wider population than mcp_server_name, and display "
        "names not slugs -- a join needs an explicit '.'/' '/':' -> '_' transform",
    ),
    ColumnSpec(
        "events",
        "mcp_server_connection",
        "status",
        "promoted",
        "mcp_connection_status",
        "TEXT",
        description="MCP connection status (connected/disconnected/failed).",
        useful_for="separates idle from broken -- retire vs fix",
        decided_at="2026-07-29",
        notes="promoted from kept (#358); failed on 9 seats, and it carries what error_code cannot",
    ),
    ColumnSpec(
        "events",
        "mcp_server_connection",
        "transport_type",
        "promoted",
        "mcp_transport_type",
        "TEXT",
        description="MCP transport (claudeai-proxy/stdio/ws-ide).",
        useful_for="hosted vs local; what IS must allow through the network",
        decided_at="2026-07-29",
        notes="promoted from kept (#358); server-static, promoted only because no server "
        "dimension exists today",
    ),
    ColumnSpec(
        "events",
        "mcp_server_connection",
        "server_scope",
        "promoted",
        "mcp_connection_server_scope",
        "TEXT",
        description="MCP server scope on the connection event "
        "(claudeai/dynamic/project/local/user).",
        decided_at="2026-07-29",
        notes="promoted from kept (#358); its own column, not shared with tool_result's "
        "mcp_server_scope -- distinct attr paths split under #354's one-path rule",
    ),
    ColumnSpec(
        "events",
        "tool_result",
        "mcp_server_scope",
        "promoted",
        "mcp_server_scope",
        "TEXT",
        description="MCP server scope on the tool-result event.",
        decided_at="2026-07-29",
        notes="promoted from kept (#358); shared vocabulary with the connection event's "
        "server_scope, separate column (#354)",
    ),
    ColumnSpec(
        "events",
        "subagent_completed",
        "agent_type",
        "promoted",
        "agent_type",
        "TEXT",
        description="Subagent type on the completion event.",
        useful_for="subagent run counts (query_source counts requests, not runs)",
        decided_at="2026-07-29",
        notes="promoted from kept (#358); own column, not an alias of agent_name -- #354 "
        "reversed that reuse: it was a density compromise and density is free here",
    ),
    ColumnSpec(
        "events",
        "subagent_completed",
        "is_async",
        "promoted",
        "subagent_is_async",
        "BOOLEAN",
        description="Background-agent flag.",
        useful_for="nothing else records background-agent use",
        decided_at="2026-07-29",
        notes="promoted from kept (#358)",
    ),
    ColumnSpec(
        "events",
        "subagent_completed",
        "total_tool_uses",
        "promoted",
        "subagent_tool_uses",
        "BIGINT",
        description="Tool calls made by the subagent.",
        useful_for="irreducible: tool_decision.query_source is NULL on all rows",
        decided_at="2026-07-29",
        notes="promoted from kept (#358)",
    ),
    ColumnSpec(
        "events",
        "subagent_completed",
        "total_tokens",
        "promoted",
        "subagent_total_tokens",
        "BIGINT",
        description="Tokens consumed by the subagent run.",
        useful_for="query_source='agent:custom' collapses every custom agent into one bucket",
        decided_at="2026-07-29",
        notes="promoted from kept (#358); own column, never a reuse of input/output_tokens -- "
        "those are per-request and a SUM across both families would double-count",
    ),
    ColumnSpec(
        "events",
        "plugin_loaded",
        "plugin.scope",
        "promoted",
        "plugin_scope",
        "TEXT",
        description="Plugin scope (official/user-local).",
        useful_for="per-seat fact: the same plugin loads official on some seats, "
        "user-local on others",
        decided_at="2026-07-29",
        notes="promoted from kept (#358)",
    ),
    ColumnSpec(
        "events",
        "plugin_loaded",
        "plugin.version",
        "promoted",
        "plugin_version",
        "TEXT",
        description="Plugin version.",
        useful_for="staleness spread across seats",
        decided_at="2026-07-29",
        notes="promoted from kept (#358); 85% fill",
    ),
    ColumnSpec(
        "events",
        "skill_activated",
        "invocation_trigger",
        "promoted",
        "skill_invocation_trigger",
        "TEXT",
        description="Skill invocation trigger (user-slash/claude-proactive/nested-skill).",
        useful_for="human pull vs model push; a slicer, never a filter baked into a measure",
        decided_at="2026-07-29",
        notes="promoted from kept (#358); deliberately not a third vocabulary on `trigger`",
    ),
    ColumnSpec(
        "events",
        "skill_activated",
        "skill.source",
        "promoted",
        "skill_source",
        "TEXT",
        description="Skill source (userSettings/projectSettings/plugin/bundled/builtin).",
        useful_for="do skills spread through the team or stay personal",
        decided_at="2026-07-29",
        notes="promoted from kept (#358); sparsest column in the batch at 0.25% populated, "
        "four times denser than the shipped mention_type (#354)",
    ),
    ColumnSpec(
        "events",
        "tool_result",
        "decision_source",
        "promoted",
        "decision_source",
        "TEXT",
        description="Who authorised the tool call (config/hook/user_temporary/...).",
        useful_for="permission friction: user_temporary on 12 of 13 seats",
        decided_at="2026-07-29",
        notes="promoted from kept (#359); `decision` says accept/reject, "
        "nothing said who authorised",
    ),
    ColumnSpec(
        "events",
        "tool_result",
        "error_type",
        "promoted",
        "error_type",
        "TEXT",
        description="Tool failure category (not the message).",
        useful_for="the only route to a failure taxonomy -- free-text `error` is denied",
        decided_at="2026-07-29",
        notes="promoted from kept (#359); ShellError 1,108 across 15 seats",
    ),
    ColumnSpec(
        "events",
        "*",
        "status_code",
        "promoted",
        "status_code",
        "SMALLINT",
        description="HTTP status code.",
        useful_for="decomposes fact_api_error_rate: 429 (tier) vs 529 (overload) vs 500 (fault)",
        decided_at="2026-07-29",
        notes="promoted from kept (#359); 24 records / 6 seats -- survives the near-zero-counter "
        "rule because it decomposes a rate the report already publishes",
    ),
    ColumnSpec(
        "events",
        "*",
        "num_hooks",
        "promoted",
        "num_hooks",
        "SMALLINT",
        description="Hooks matched for the event.",
        useful_for="how much hook machinery the fleet runs",
        decided_at="2026-07-29",
        notes="promoted from kept (#359); populates across hook_execution_start / "
        "hook_execution_complete / hook_registered, not one family",
    ),
    ColumnSpec(
        "events",
        "hook_execution_complete",
        "num_success",
        "promoted",
        "num_success",
        "SMALLINT",
        description="Hooks that succeeded.",
        useful_for="with num_hooks, states the failure count exactly",
        decided_at="2026-07-29",
        notes="promoted from kept (#359); the failure *mode* split stays kept -- "
        "num_hooks - num_success equals the three mode counters on all 17,077 records",
    ),
    ColumnSpec(
        "events",
        "*",
        "hook_source",
        "promoted",
        "hook_source",
        "TEXT",
        description="Where the hook came from (settings/pluginHook/...).",
        useful_for="attributes hook load to plugins, which the plugin columns cannot",
        decided_at="2026-07-29",
        notes="promoted from kept (#359); populates across three hook families",
    ),
    ColumnSpec(
        "events",
        "hook_execution_complete",
        "total_duration_ms",
        "promoted",
        "total_duration_ms",
        "BIGINT",
        description="Total time across the hooks run for one event.",
        useful_for="hook overhead: bridge_session_hook has executions and no time",
        decided_at="2026-07-29",
        notes="promoted from kept (#359); own column, not an alias of duration_ms -- #354 "
        "reversed that reuse. A sum over N hooks is not one operation's latency",
    ),
    # ===== events: kept (blob-only) =====
    ColumnSpec(
        "events",
        "*",
        "user.id",
        "kept",
        description="Anonymous install id.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "event.timestamp",
        "kept",
        description="ISO event timestamp.",
        decided_at="2026-07-13",
        notes="we use timeUnixNano for event_time",
    ),
    ColumnSpec(
        "events",
        "*",
        "client_request_id",
        "kept",
        description="Client request id.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events", "*", "attempt", "kept", description="API attempt number.", decided_at="2026-07-13"
    ),
    ColumnSpec(
        "events",
        "*",
        "stop_reason",
        "kept",
        description="Model stop reason.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "workspace.host_paths",
        "kept",
        description="Desktop workspace dirs.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "cost_usd_micros",
        "kept",
        description="Cost in micros.",
        decided_at="2026-07-13",
        notes="we use cost_usd",
    ),
    ColumnSpec(
        "events", "*", "safe_mode", "kept", description="Safe-mode flag.", decided_at="2026-07-13"
    ),
    ColumnSpec(
        "events",
        "*",
        "managed_only",
        "kept",
        description="Managed-only flag.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "*",
        "plugin_id_hash",
        "kept",
        description="Plugin id hash.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "assistant_response",
        "response_length",
        "kept",
        description="Response length in chars.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "assistant_response",
        "message.uuid",
        "kept",
        description="Message UUID.",
        decided_at="2026-07-29",
        notes="kept basis collinear (#359): covered by the promoted prompt_id, which reaches all "
        "three families",
    ),
    ColumnSpec(
        "events",
        "user_prompt",
        "message.uuid",
        "kept",
        description="Message UUID.",
        decided_at="2026-07-29",
        notes="kept basis collinear (#359): covered by the promoted prompt_id",
    ),
    ColumnSpec(
        "events",
        "hook_execution_complete",
        "num_blocking",
        "kept",
        description="Blocking hooks.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "hook_execution_complete",
        "num_non_blocking_error",
        "kept",
        description="Non-blocking hook errors.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "hook_execution_complete",
        "num_cancelled",
        "kept",
        description="Cancelled hooks.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "hook_registered",
        "hook_matcher",
        "kept",
        description="Hook matcher pattern.",
        decided_at="2026-07-13",
        notes="details-gated",
    ),
    ColumnSpec(
        "events",
        "hook_registered",
        "hook_type",
        "kept",
        description="Hook type.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "plugin_loaded",
        "enabled_via",
        "kept",
        description="Plugin enablement source.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "plugin_loaded",
        "has_hooks",
        "kept",
        description="Plugin declares hooks.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "plugin_loaded",
        "has_mcp",
        "kept",
        description="Plugin declares MCP.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "plugin_loaded",
        "host_owned_mcp",
        "kept",
        description="Host-owned MCP flag.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "plugin_loaded",
        "skill_path_count",
        "kept",
        description="Skill path count.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "plugin_loaded",
        "command_path_count",
        "kept",
        description="Command path count.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "plugin_loaded",
        "agent_path_count",
        "kept",
        description="Agent path count.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "plugin_installed",
        "install.trigger",
        "kept",
        description="Install trigger (cli/ui).",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "plugin_installed",
        "marketplace.is_official",
        "kept",
        description="Official-marketplace flag.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "skill_activated",
        "skill.kind",
        "kept",
        description="Skill kind (workflow).",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "subagent_completed",
        "agent.source",
        "kept",
        description="Subagent source.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "subagent_completed",
        "is_built_in",
        "kept",
        description="Built-in subagent flag.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "subagent_completed",
        "final_model",
        "kept",
        description="Model the subagent finished on.",
        decided_at="2026-07-29",
        notes="kept basis collinear (#358): api_request already carries `model` alongside the "
        "agent-bearing query_source, so model-per-agent exists at request grain",
    ),
    ColumnSpec(
        "events",
        "subagent_completed",
        "model_swapped",
        "kept",
        description="Whether the subagent's model changed mid-run.",
        decided_at="2026-07-29",
        notes="kept basis constant (#370): `False` on all 794 records in the profiled window "
        "(promotion-candidate-profile.md, *Settled by the evidence*); re-measured 2026-07-29 over "
        "2026-07-14..28 -- still one value",
    ),
    ColumnSpec(
        "events",
        "feedback_survey",
        "event_type",
        "kept",
        description="Survey event type.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "feedback_survey",
        "appearance_id",
        "kept",
        description="Survey appearance id.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "feedback_survey",
        "survey_type",
        "kept",
        description="Survey type.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "feedback_survey",
        "enabled_via_override",
        "kept",
        description="Survey override flag.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "feedback_survey",
        "event_origin",
        "kept",
        description="Where the survey event originated.",
        decided_at="2026-07-29",
        notes="kept basis constant (#370): `sdk_host` on all 10 records in the profiled window "
        "(promotion-candidate-profile.md, *Settled by the evidence*)",
    ),
    ColumnSpec(
        "events",
        "feedback_survey",
        "event_origin_server",
        "kept",
        description="Server that originated the survey event.",
        decided_at="2026-07-29",
        notes="kept basis constant (#370): `claude-vscode` on all 10 records in the profiled "
        "window (promotion-candidate-profile.md, *Settled by the evidence*)",
    ),
    ColumnSpec(
        "events",
        "internal_error",
        "error_name",
        "kept",
        description="Error class name (no message).",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "internal_error",
        "error_code",
        "kept",
        description="errno (e.g. ENOENT).",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "api_retries_exhausted",
        "total_attempts",
        "kept",
        description="Total attempts.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "api_retries_exhausted",
        "total_retry_duration_ms",
        "kept",
        description="Total retry duration.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "api_refusal",
        "category",
        "kept",
        description="Refusal category enum.",
        decided_at="2026-07-13",
        notes="enum kept per #8",
    ),
    ColumnSpec(
        "events",
        "api_refusal",
        "has_category",
        "kept",
        description="Refusal has-category flag.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "api_refusal",
        "has_explanation",
        "kept",
        description="Refusal has-explanation flag.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "api_refusal",
        "server_fallback_hop",
        "kept",
        description="Server fallback hop.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "mcp_server_connection",
        "error_code",
        "kept",
        description="Connection error code.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "mcp_server_connection",
        "is_plugin",
        "kept",
        description="Plugin-provided MCP flag.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "tool_result",
        "tool_input_size_bytes",
        "kept",
        description="Tool input size.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "tool_result",
        "tool_result_size_bytes",
        "kept",
        description="Tool result size.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "tool_result",
        "decision_type",
        "kept",
        description="Decision type.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "tool_result",
        "tool_input",
        "denied",
        deny_mode="strip",
        description="Tool args JSON (details-gated).",
        decided_at="2026-07-29",
        notes="#369: full command lines + absolute developer paths; was kept until measured",
    ),
    ColumnSpec(
        "events",
        "tool_result",
        "tool_parameters",
        "denied",
        deny_mode="strip",
        description="Tool args JSON (details-gated).",
        decided_at="2026-07-29",
        notes="#369: emitted as a JSON string, so the leaf sweep never reached it",
    ),
    ColumnSpec(
        "events",
        "tool_decision",
        "tool_source",
        "kept",
        description="Where the tool came from (builtin/mcp/sdk_host_builtin_mcp).",
        decided_at="2026-07-29",
        notes="kept basis collinear (#358): redundant with the promoted tool_name='mcp_tool' -- "
        "1,027 rows both ways, adds 34 of 49,250 (0.07%)",
    ),
    ColumnSpec(
        "events",
        "tool_decision",
        "tool_parameters",
        "denied",
        deny_mode="strip",
        description="Tool args JSON (details-gated).",
        decided_at="2026-07-29",
        notes="#369: emitted as a JSON string, so the leaf sweep never reached it",
    ),
    ColumnSpec(
        "events", "auth", "action", "kept", description="login/logout.", decided_at="2026-07-13"
    ),
    ColumnSpec(
        "events", "auth", "auth_method", "kept", description="Auth method.", decided_at="2026-07-13"
    ),
    ColumnSpec(
        "events",
        "auth",
        "error_category",
        "kept",
        description="Auth error category (no message).",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "compaction",
        "pre_tokens",
        "kept",
        description="Pre-compaction tokens.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "compaction",
        "post_tokens",
        "kept",
        description="Post-compaction tokens.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "compaction",
        "precompute_reuse",
        "kept",
        description="Precompute-reuse outcome.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "hook_plugin_metrics",
        "plugin_id",
        "kept",
        description="Plugin id (name@marketplace).",
        decided_at="2026-07-13",
    ),
    # ===== gateway / version-added standard + body-metadata keys (blob-only) =====
    ColumnSpec(
        "metrics",
        "*",
        "user.groups",
        "kept",
        description="IdP group membership (gateway sessions).",
        decided_at="2026-07-13",
        notes="gateway-oidc identity",
    ),
    ColumnSpec(
        "metrics",
        "*",
        "identity.source",
        "kept",
        description="Identity source (e.g. gateway-oidc).",
        decided_at="2026-07-13",
        notes="gateway sessions",
    ),
    ColumnSpec(
        "events",
        "*",
        "user.groups",
        "kept",
        description="IdP group membership (gateway sessions).",
        decided_at="2026-07-13",
        notes="gateway-oidc identity",
    ),
    ColumnSpec(
        "events",
        "*",
        "identity.source",
        "kept",
        description="Identity source (e.g. gateway-oidc).",
        decided_at="2026-07-13",
        notes="gateway sessions",
    ),
    ColumnSpec(
        "events",
        "*",
        "workflow.run_id",
        "kept",
        description="Workflow run id (wf_...) on workflow-spawned agents.",
        decided_at="2026-07-13",
        notes="v2.1.202+",
    ),
    ColumnSpec(
        "events",
        "api_request_body",
        "body_length",
        "kept",
        description="Raw API request body length.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "api_request_body",
        "body_truncated",
        "kept",
        description="Raw API request body truncated flag.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "api_response_body",
        "body_length",
        "kept",
        description="Raw API response body length.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "api_response_body",
        "body_truncated",
        "kept",
        description="Raw API response body truncated flag.",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "hook_execution_start",
        "hook_definitions",
        "kept",
        description="Hook definitions (detailed-beta/details gated).",
        decided_at="2026-07-13",
    ),
    ColumnSpec(
        "events",
        "hook_execution_complete",
        "hook_definitions",
        "kept",
        description="Hook definitions (detailed-beta/details gated).",
        decided_at="2026-07-13",
    ),
    # ===== events: denied (#8 redaction denylist) =====
    ColumnSpec(
        "events",
        "*",
        "full_command",
        "denied",
        deny_mode="strip",
        description="Full command line.",
        decided_at="2026-07-13",
        notes="#8 denylist (POC four); sink strips wherever seen",
    ),
    ColumnSpec(
        "events",
        "*",
        "bash_command",
        "denied",
        deny_mode="strip",
        description="Bash command.",
        decided_at="2026-07-13",
        notes="#8 denylist (POC four)",
    ),
    ColumnSpec(
        "events",
        "*",
        "file_path",
        "denied",
        deny_mode="strip",
        description="File path.",
        decided_at="2026-07-13",
        notes="#8 denylist (POC four)",
    ),
    ColumnSpec(
        "events",
        "*",
        "error",
        "denied",
        deny_mode="strip",
        description="Error message.",
        decided_at="2026-07-13",
        notes="#8 denylist (POC four); error_name/error_code/error_type kept",
    ),
    ColumnSpec(
        "events",
        "user_prompt",
        "prompt",
        "denied",
        deny_mode="defense_in_depth",
        description="Prompt text.",
        decided_at="2026-07-13",
        notes="#8 defense-in-depth (client gate OTEL_LOG_USER_PROMPTS=0)",
    ),
    ColumnSpec(
        "events",
        "assistant_response",
        "response",
        "denied",
        deny_mode="defense_in_depth",
        description="Assistant response text.",
        decided_at="2026-07-13",
        notes="#8 defense-in-depth (client gate OTEL_LOG_ASSISTANT_RESPONSES=0)",
    ),
    ColumnSpec(
        "events",
        "feedback_survey",
        "response",
        "denied",
        deny_mode="defense_in_depth",
        description="Survey free-text response.",
        decided_at="2026-07-13",
        notes="#8 defense-in-depth",
    ),
    ColumnSpec(
        "events",
        "api_request_body",
        "body",
        "denied",
        deny_mode="defense_in_depth",
        description="Raw API request body.",
        decided_at="2026-07-13",
        notes="#8 defense-in-depth (client gate OTEL_LOG_RAW_API_BODIES=0)",
    ),
    ColumnSpec(
        "events",
        "api_request_body",
        "body_ref",
        "denied",
        deny_mode="defense_in_depth",
        description="Raw API request body file ref.",
        decided_at="2026-07-13",
        notes="#8 defense-in-depth",
    ),
    ColumnSpec(
        "events",
        "api_response_body",
        "body",
        "denied",
        deny_mode="defense_in_depth",
        description="Raw API response body.",
        decided_at="2026-07-13",
        notes="#8 defense-in-depth",
    ),
    ColumnSpec(
        "events",
        "api_response_body",
        "body_ref",
        "denied",
        deny_mode="defense_in_depth",
        description="Raw API response body file ref.",
        decided_at="2026-07-13",
        notes="#8 defense-in-depth",
    ),
)


# --- pure derivations (import-time constants for the sink consumers) ----------


def attr_columns(signal: Signal) -> dict[str, str]:
    """Flat ``attr_path -> column_name`` map for a signal's promoted ``attr`` rows.

    Collapses per-signal-name grain to the flat map the parser applies: an attr
    key is globally unique to its target column, so duplicate rows (``type`` on
    three metrics, ``duration_ms`` on four events) map to the same column.
    """
    out: dict[str, str] = {}
    for r in COLUMN_SPEC:
        if r.signal == signal and r.status == "promoted" and r.kind == "attr":
            assert r.column_name is not None  # invariant 2
            out[r.attr_path] = r.column_name
    return out


def derived_coalesce(
    signal: Signal, spec: tuple[ColumnSpec, ...] = COLUMN_SPEC
) -> dict[str, list[str]]:
    """Ordered coalesce sources per ``derived`` column for a signal.

    Each derived column maps to the attr paths the parser tries in order,
    first truthy value wins (``||`` semantics — a falsy/empty attr falls
    through): own-signal derived rows in file order, then
    resource-signal derived rows in file order. This mirrors the parser's
    attr-merge semantics (datapoint attrs shadow resource attrs), so it
    reproduces ``user_account_id`` and ``cc_version`` with no per-column code.
    A path repeated across the two signals is kept once, in first-seen order, so
    the union is idempotent.
    """
    out: dict[str, list[str]] = {}
    for sig in dict.fromkeys((signal, "resource")):
        for r in spec:
            if r.signal == sig and r.status == "promoted" and r.kind == "derived":
                assert r.column_name is not None  # invariant 2
                sources = out.setdefault(r.column_name, [])
                if r.attr_path not in sources:
                    sources.append(r.attr_path)
    return out


def promoted_columns(
    signal: Signal, spec: tuple[ColumnSpec, ...] = COLUMN_SPEC
) -> tuple[ColumnSpec, ...]:
    """Promoted rows owning a column on ``raw.<signal>``, in spec order.

    A promoted ``resource`` row counts for **both** raw tables. A resource
    attribute is registered once, as ``resource``/``*`` (the curation runbook's
    rule), and the sink merges the resource block into each signal's flat
    namespace — so ``derived_coalesce`` writes it for metrics and events alike and
    the DDL has to carry it on both (#357 ``service_name`` / ``os_type``).
    """
    return tuple(
        r
        for r in spec
        if r.status == "promoted" and r.column_name is not None and r.signal in (signal, "resource")
    )


def table_columns(signal: Signal, spec: tuple[ColumnSpec, ...] = COLUMN_SPEC) -> tuple[str, ...]:
    """Distinct promoted column names for a signal's raw table, in spec order."""
    seen: set[str] = set()
    out: list[str] = []
    for r in promoted_columns(signal, spec):
        assert r.column_name is not None  # promoted_columns filters on it
        if r.column_name not in seen:
            seen.add(r.column_name)
            out.append(r.column_name)
    return tuple(out)


def _typed_columns(types: frozenset[str]) -> frozenset[str]:
    return frozenset(
        r.column_name
        for r in COLUMN_SPEC
        if r.status == "promoted" and r.data_type in types and r.column_name is not None
    )


def int_columns() -> frozenset[str]:
    """Promoted columns coerced to ``int`` (BIGINT/INTEGER/SMALLINT)."""
    return _typed_columns(_INT_TYPES)


def float_columns() -> frozenset[str]:
    """Promoted columns coerced to ``float`` (DOUBLE PRECISION)."""
    return _typed_columns(frozenset({"DOUBLE PRECISION"}))


def bool_columns() -> frozenset[str]:
    """Promoted columns coerced to ``bool`` (BOOLEAN)."""
    return _typed_columns(frozenset({"BOOLEAN"}))


def _denied(mode: DenyMode) -> tuple[ColumnSpec, ...]:
    return tuple(r for r in COLUMN_SPEC if r.status == "denied" and r.deny_mode == mode)


def denylist() -> frozenset[str]:
    """Secret-bearing keys stripped from every attribute list (``strip``)."""
    return frozenset(r.attr_path for r in _denied("strip"))


def defense_in_depth() -> frozenset[str]:
    """Content keys a client gate suppresses; a non-empty hit is drift."""
    return frozenset(r.attr_path for r in _denied("defense_in_depth"))


RegistryRow = tuple[str, str, str, str, str | None, str | None, str, str | None, str, str | None]


def registry_rows(spec: tuple[ColumnSpec, ...] = COLUMN_SPEC) -> tuple[RegistryRow, ...]:
    """Project spec rows to the ``meta.column_registry`` column order.

    ``kind`` and ``deny_mode`` are sink-side and are not projected — the registry
    is the deployed projection of the spec, not a full mirror. ``tools.spec_sync``
    diffs this against the live registry.
    """
    return tuple(
        (
            r.signal,
            r.signal_name,
            r.attr_path,
            r.status,
            r.column_name,
            r.data_type,
            r.description,
            r.useful_for,
            r.decided_at,
            r.notes,
        )
        for r in spec
    )


# --- signal catalog: literals mart SQL may reference (#168) -------------------
#
# Mart SQL re-encodes metric-name and enum literals verbatim; a typo silently
# yields zero rows. ``tools.spec_sync`` lints ``db/migrations/*.sql`` against this
# catalog so an unknown literal fails the gate. Seeded from the data dictionary
# (metric names) and the promoted enum decisions above (``type_label`` /
# ``value_kind`` descriptions).

METRIC_NAMES: frozenset[str] = frozenset(
    {
        "claude_code.session.count",
        "claude_code.lines_of_code.count",
        "claude_code.pull_request.count",
        "claude_code.commit.count",
        "claude_code.cost.usage",
        "claude_code.token.usage",
        "claude_code.code_edit_tool.decision",
        "claude_code.active_time.total",
        "claude_code.usage.utilization",
        "claude_code.usage.reset_in_seconds",
    }
)

# Enum value sets keyed by the raw/staging column that carries them. Flat per
# column (not per metric): the lint is a tripwire, not a SQL parser.
ENUM_VALUES: dict[str, frozenset[str]] = {
    # token.usage: input/output/cacheRead/cacheCreation; active_time: user/cli;
    # lines_of_code: added/removed.
    "type_label": frozenset(
        {"input", "output", "cacheRead", "cacheCreation", "user", "cli", "added", "removed"}
    ),
    # derived staging classification (dataPoint.value_kind).
    "value_kind": frozenset({"gauge_last", "sum_delta", "sum_cumulative", "hist_sum"}),
}


# --- invariants (run once at import) ------------------------------------------


def _check_invariants(spec: tuple[ColumnSpec, ...] = COLUMN_SPEC) -> None:
    seen: set[tuple[str, str, str]] = set()
    col_types: dict[tuple[str, str], str] = {}
    attr_to_col: dict[tuple[str, str], str] = {}
    col_to_attr: dict[tuple[str, str], str] = {}
    for r in spec:
        key = (r.signal, r.signal_name, r.attr_path)
        if key in seen:  # invariant 1: grain uniqueness
            raise ValueError(f"duplicate spec row: {key}")
        seen.add(key)

        # invariant 2: status <-> column mapping (mirrors column_registry_promoted_chk)
        if r.status == "promoted":
            if r.column_name is None or r.data_type is None:
                raise ValueError(f"promoted row missing column/type: {key}")
            if r.deny_mode is not None:
                raise ValueError(f"promoted row must not set deny_mode: {key}")
        else:
            if r.column_name is not None or r.data_type is not None:
                raise ValueError(f"{r.status} row must not set column/type: {key}")
            if r.status == "denied" and r.deny_mode is None:
                raise ValueError(f"denied row missing deny_mode: {key}")
            if r.status == "kept" and r.deny_mode is not None:
                raise ValueError(f"kept row must not set deny_mode: {key}")

        # invariant 3: same column within one signal => same data_type (coalesce groups)
        if r.column_name is not None and r.data_type is not None:
            grp = (r.signal, r.column_name)
            prev = col_types.get(grp)
            if prev is not None and prev != r.data_type:
                raise ValueError(f"column {r.column_name} has conflicting types in {r.signal}")
            col_types[grp] = r.data_type

        # invariant 5: an attr path maps to exactly one column per signal (a
        # duplicate is silent last-write-wins in the flat attr/coalesce maps).
        if r.status == "promoted":
            assert r.column_name is not None  # invariant 2 above
            ak = (r.signal, r.attr_path)
            prev_col = attr_to_col.get(ak)
            if prev_col is not None and prev_col != r.column_name:
                raise ValueError(f"attr {r.attr_path} maps to multiple columns in {r.signal}")
            attr_to_col[ak] = r.column_name

        # invariant 8: the reverse of 5 — a kind="attr" column has exactly one attr
        # path per signal (#354's one-path rule). Two paths on one column is silent
        # last-spec-row-wins in ``_apply_promoted``'s key-by-key pass the moment a
        # record carries both; density is never a reason to alias. Only ``derived``
        # is exempt — multi-source coalesce is what that kind is for.
        if r.status == "promoted" and r.kind == "attr":
            assert r.column_name is not None  # invariant 2 above
            ck = (r.signal, r.column_name)
            prev_attr = col_to_attr.get(ck)
            if prev_attr is not None and prev_attr != r.attr_path:
                raise ValueError(
                    f"column {r.column_name} fed by multiple attr paths in {r.signal}: "
                    f"{prev_attr}, {r.attr_path}"
                )
            col_to_attr[ck] = r.attr_path

    # invariant 4: every named metric grain is in the lint catalog (#168) — the
    # catalog carries metrics with no spec row too (commit/pr/cost), so this is
    # subset, not equality.
    spec_metrics = {r.signal_name for r in spec if r.signal == "metrics" and r.signal_name != "*"}
    if not spec_metrics <= METRIC_NAMES:
        raise ValueError(f"metric grains absent from METRIC_NAMES: {spec_metrics - METRIC_NAMES}")

    # invariant 7: a kept/denied row must not contradict a promoted row for the
    # same attr path (#353). ``attr_columns(signal)`` drops signal_name, so the
    # column is written whatever the name — a 'kept' row ("no Postgres column")
    # is then false. Its reach is the signals whose flat map writes the column:
    # its own, plus metrics/events when the row is the resource mirror the sweep
    # falls back to (``tools._registry``). 'denied' reaches further and is worse:
    # ``denylist()`` drops the signal, so redaction strips the key everywhere and
    # the promoted column silently never populates.
    promoted: dict[str, set[str]] = {}
    for r in spec:
        if r.status == "promoted":
            promoted.setdefault(r.signal, set()).add(r.attr_path)
    signal_promoted = promoted.get("metrics", set()) | promoted.get("events", set())
    any_promoted = signal_promoted | promoted.get("resource", set())
    for r in spec:
        if r.status == "promoted":
            continue
        key = (r.signal, r.signal_name, r.attr_path)
        if r.status == "denied":
            if r.attr_path in any_promoted:
                raise ValueError(f"denied row contradicts a promoted row: {key}")
        elif r.attr_path in promoted.get(r.signal, set()):
            raise ValueError(f"kept row contradicts a promoted row in {r.signal}: {key}")
        elif r.signal == "resource" and r.attr_path in signal_promoted:
            raise ValueError(f"kept resource row contradicts a promoted signal row: {key}")

    # invariant 9: a promoted resource row projects its column onto both raw tables
    # (``promoted_columns``), so the projection has to be answerable there. Where an
    # own-signal row already declares the column, the two must agree on type —
    # ``spec_raw_columns`` builds one dict per table and would silently take
    # whichever row came last. Where none does, the resource row is the column's only
    # source and must be ``derived``: ``attr_columns(signal)`` keys on the row's own
    # signal, so a resource ``attr`` row writes nothing and the column is minted
    # always-NULL (#357 ``service_name`` / ``os_type``).
    # Keyed by (signal, column_name), not column_name alone: the projection lands on
    # both tables, so it has to agree with both own-signal rows — a single-key lookup
    # keeps whichever signal came last in spec order.
    own_types: dict[tuple[str, str], str] = {}
    for r in spec:
        if r.status == "promoted" and r.signal != "resource" and r.column_name and r.data_type:
            own_types[(r.signal, r.column_name)] = r.data_type
    for r in spec:
        if r.status != "promoted" or r.signal != "resource" or r.column_name is None:
            continue
        owns = {sig: t for (sig, col), t in own_types.items() if col == r.column_name}
        if not owns:
            if r.kind != "derived":
                raise ValueError(
                    f"resource-only column {r.column_name} must be kind='derived', "
                    f"not {r.kind!r} — an attr row writes it on no signal"
                )
        for sig, own in sorted(owns.items()):
            if own != r.data_type:
                raise ValueError(
                    f"column {r.column_name} type differs between the resource row "
                    f"({r.data_type}) and its {sig} row ({own})"
                )


_check_invariants()
