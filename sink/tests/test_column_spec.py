"""The spec derivations reproduce the previously hand-maintained tables (#167).

Expected values are frozen literals (the pre-refactor constants), so these assert
the spec *produces* them — a genuine regression guard, not a tautology once the
consumers derive from the spec.
"""

from __future__ import annotations

from cc_otel_sink import column_spec as cs
from cc_otel_sink.parser import EVENT_ATTR_COLUMNS, METRIC_ATTR_COLUMNS, parse_events, parse_metrics
from cc_otel_sink.store import EVENT_COLUMNS, METRIC_COLUMNS

_EXPECTED_METRIC_ATTR = {
    "session.id": "session_id",
    "user.email": "user_email",
    "organization.id": "organization_id",
    "model": "model",
    "query_source": "query_source",
    "effort": "effort",
    "speed": "speed",
    "agent.name": "agent_name",
    "skill.name": "skill_name",
    "plugin.name": "plugin_name",
    "marketplace.name": "marketplace_name",
    "type": "type_label",
    "tool_name": "tool_name",
    "decision": "decision",
    "source": "source",
    "language": "language",
    "start_type": "start_type",
    "window": "usage_window",
}

_EXPECTED_EVENT_ATTR = {
    "session.id": "session_id",
    "prompt.id": "prompt_id",
    "user.email": "user_email",
    "organization.id": "organization_id",
    "model": "model",
    "request_id": "request_id",
    "speed": "speed",
    "effort": "effort",
    "query_source": "query_source",
    "skill.name": "skill_name",
    "agent.name": "agent_name",
    "plugin.name": "plugin_name",
    "marketplace.name": "marketplace_name",
    "mcp_server.name": "mcp_server_name",
    "mcp_tool.name": "mcp_tool_name",
    "tool_name": "tool_name",
    "tool_use_id": "tool_use_id",
    "decision": "decision",
    "source": "source",
    "hook_name": "hook_name",
    "hook_event": "hook_event",
    "event.sequence": "event_sequence",
    "input_tokens": "input_tokens",
    "output_tokens": "output_tokens",
    "cache_creation_tokens": "cache_creation_tokens",
    "cache_read_tokens": "cache_read_tokens",
    "cost_usd": "cost_usd",
    "duration_ms": "duration_ms",
    "prompt_length": "prompt_length",
    "command_name": "command_name",
    "command_source": "command_source",
    "from_mode": "from_mode",
    "to_mode": "to_mode",
    "trigger": "trigger",
    "mention_type": "mention_type",
    "success": "success_bool",
}


def test_attr_columns_match_the_flat_maps() -> None:
    assert cs.attr_columns("metrics") == _EXPECTED_METRIC_ATTR
    assert cs.attr_columns("events") == _EXPECTED_EVENT_ATTR


def test_table_columns_cover_the_raw_ddl_column_sets() -> None:
    # Sets, not ordinals: the insert names its columns (store._insert_sql), so the
    # spec order is free (gate compares sets + types, per the design).
    assert set(cs.table_columns("metrics")) == set(METRIC_COLUMNS)
    assert set(cs.table_columns("events")) == set(EVENT_COLUMNS)


def test_typed_column_sets_match() -> None:
    assert cs.int_columns() == frozenset(
        {
            "count",
            "duration_ms",
            "input_tokens",
            "output_tokens",
            "cache_creation_tokens",
            "cache_read_tokens",
            "event_sequence",
            "prompt_length",
            "severity_number",
            "dropped_attributes_count",
        }
    )
    assert cs.float_columns() == frozenset({"value", "cost_usd"})
    assert cs.bool_columns() == frozenset({"success_bool"})


def test_redaction_sets_match() -> None:
    assert cs.denylist() == frozenset({"full_command", "bash_command", "file_path", "error"})
    assert cs.tool_param_keys() == frozenset({"full_command", "bash_command", "file_path"})
    assert cs.defense_in_depth() == frozenset({"prompt", "response", "body", "body_ref"})


def _attr_list(pairs: dict[str, str]) -> list[dict[str, object]]:
    return [{"key": k, "value": {"stringValue": v}} for k, v in pairs.items()]


_RESOURCE = [{"key": "service.version", "value": {"stringValue": "1.0"}}]


def _typed_attr_list(mapping: dict[str, str]) -> list[dict[str, object]]:
    """One attribute per key, its value typed to match the target column."""
    ints, floats, bools = cs.int_columns(), cs.float_columns(), cs.bool_columns()
    out: list[dict[str, object]] = []
    for key, col in mapping.items():
        if col in ints:
            value: dict[str, object] = {"intValue": "1"}
        elif col in floats:
            value = {"doubleValue": 1.0}
        elif col in bools:
            value = {"boolValue": True}
        else:
            value = {"stringValue": key}
        out.append({"key": key, "value": value})
    return out


def test_every_promoted_metric_column_is_populated_by_the_parser() -> None:
    # A gauge carrying every metrics attr key + the derived coalesce sources, plus
    # a histogram to exercise `count`. Each promoted column must appear as a row key.
    attrs = {k: k for k in METRIC_ATTR_COLUMNS}
    attrs |= {"user.account_uuid": "u", "app.version": "1.0"}
    payload = {
        "resourceMetrics": [
            {
                "resource": {"attributes": _RESOURCE},
                "scopeMetrics": [
                    {
                        "scope": {"name": "cc", "version": "1"},
                        "metrics": [
                            {
                                "name": "claude_code.code_edit_tool.decision",
                                "gauge": {
                                    "dataPoints": [
                                        {
                                            "timeUnixNano": "1",
                                            "asDouble": 1.0,
                                            "attributes": _attr_list(attrs),
                                        }
                                    ]
                                },
                            },
                            {
                                "name": "claude_code.token.usage",
                                "histogram": {
                                    "dataPoints": [{"timeUnixNano": "1", "count": "3", "sum": 2.0}]
                                },
                            },
                        ],
                    }
                ],
            }
        ]
    }
    keys: set[str] = set()
    for row in parse_metrics(payload):
        keys |= row.keys()
    assert set(cs.table_columns("metrics")) <= keys


def test_every_promoted_event_column_is_populated_by_the_parser() -> None:
    attributes = _typed_attr_list(EVENT_ATTR_COLUMNS) + _attr_list(
        {"event.name": "api_request", "user.account_uuid": "u", "app.version": "1.0"}
    )
    payload = {
        "resourceLogs": [
            {
                "resource": {"attributes": _RESOURCE},
                "scopeLogs": [
                    {
                        "scope": {"name": "cc", "version": "1"},
                        "logRecords": [
                            {
                                "timeUnixNano": "1",
                                "severityText": "INFO",
                                "severityNumber": 9,
                                "traceId": "t",
                                "spanId": "s",
                                "droppedAttributesCount": 0,
                                "body": {"stringValue": "api_request"},
                                "attributes": attributes,
                            }
                        ],
                    }
                ],
            }
        ]
    }
    keys: set[str] = set()
    for row in parse_events(payload):
        keys |= row.keys()
    assert set(cs.table_columns("events")) <= keys
