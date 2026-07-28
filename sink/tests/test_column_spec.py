"""The spec derivations reproduce the previously hand-maintained tables (#167).

Expected values are frozen literals (the pre-refactor constants), so these assert
the spec *produces* them — a genuine regression guard, not a tautology once the
consumers derive from the spec.
"""

from __future__ import annotations

from dataclasses import replace

import pytest
from cc_otel_sink import column_spec as cs
from cc_otel_sink import parser
from cc_otel_sink.column_spec import COLUMN_SPEC, ColumnSpec
from cc_otel_sink.parser import EVENT_ATTR_COLUMNS, METRIC_ATTR_COLUMNS, parse_events, parse_metrics
from cc_otel_sink.store import EVENT_COLUMNS, METRIC_COLUMNS

_EXPECTED_METRIC_ATTR = {
    "session.id": "session_id",
    "user.email": "user_email",
    "process.owner": "process_owner",
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
    "process.owner": "process_owner",
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


def test_derived_coalesce_orders_own_signal_then_resource() -> None:
    # Own-signal derived rows in file order, then resource-signal derived rows in
    # file order — reproducing the parser's attr-shadows-resource coalesce.
    assert cs.derived_coalesce("metrics") == {
        "user_account_id": ["user.account_uuid", "user.account_id"],
        "cc_version": ["app.version", "service.version"],
    }
    assert cs.derived_coalesce("events") == {
        "user_account_id": ["user.account_uuid", "user.account_id"],
        "cc_version": ["app.version", "service.version"],
    }


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


def test_duplicate_attr_key_to_different_columns_rejected() -> None:
    # Same (signal, attr_path) mapping to two columns is silent last-write-wins in
    # the flat attr map — reject it at import. Distinct signal_name keeps grain
    # uniqueness (invariant 1) from firing first.
    bad = COLUMN_SPEC + (
        ColumnSpec("metrics", "claude_code.token.usage", "session.id", "promoted", "other", "TEXT"),
    )
    with pytest.raises(ValueError, match="multiple columns"):
        cs._check_invariants(bad)


def test_malformed_tool_param_sweep_path_rejected() -> None:
    # A tool_param_sweep path must be tool_parameters.<leaf>; a bare key would
    # IndexError in tool_param_keys() at import — turn it into a clear failure.
    bad = COLUMN_SPEC + (
        ColumnSpec("events", "tool_result", "full_command", "denied", deny_mode="tool_param_sweep"),
    )
    with pytest.raises(ValueError, match="tool_parameters"):
        cs._check_invariants(bad)


def test_wellformed_tool_param_sweep_path_accepted() -> None:
    ok = COLUMN_SPEC + (
        ColumnSpec(
            "events",
            "tool_result",
            "tool_parameters.some_leaf",
            "denied",
            deny_mode="tool_param_sweep",
        ),
    )
    cs._check_invariants(ok)  # no raise


def test_kept_row_contradicting_a_promoted_row_in_the_same_signal_rejected() -> None:
    # attr_columns(signal) drops signal_name, so the column is written under every
    # event name — a `kept` row ("no Postgres column") for the same path states
    # something false. This is the class that let events/compaction/trigger sit
    # `kept` while raw.events.trigger carried 57 compaction rows (#353).
    bad = COLUMN_SPEC + (ColumnSpec("events", "some_event", "prompt_length", "kept"),)
    with pytest.raises(ValueError, match="contradicts a promoted row in events"):
        cs._check_invariants(bad)


def test_denied_row_contradicting_a_promoted_row_in_the_same_signal_rejected() -> None:
    # Worse than `kept`: redaction strips the key everywhere, so the promoted
    # column silently never populates.
    bad = COLUMN_SPEC + (
        ColumnSpec("events", "some_event", "prompt_length", "denied", deny_mode="strip"),
    )
    with pytest.raises(ValueError, match="denied row contradicts"):
        cs._check_invariants(bad)


def test_denied_row_contradicting_a_promoted_row_in_another_signal_rejected() -> None:
    # denylist() and tool_param_keys() carry no signal, so redaction is global: a
    # denied `events` row for `window` would blank raw.metrics.usage_window, which
    # `window` is promoted to under metrics only. Wider reach than the kept case.
    bad = COLUMN_SPEC + (ColumnSpec("events", "some_event", "window", "denied", deny_mode="strip"),)
    with pytest.raises(ValueError, match="denied row contradicts"):
        cs._check_invariants(bad)


def test_kept_resource_row_contradicting_a_promoted_signal_row_rejected() -> None:
    # Cross-signal form of the same lie, reachable through the sweep's resource/*
    # fallback: the resource row denies a column metrics/events actually write.
    bad = COLUMN_SPEC + (ColumnSpec("resource", "*", "prompt_length", "kept"),)
    with pytest.raises(ValueError, match="resource row contradicts"):
        cs._check_invariants(bad)


def test_derived_coalesce_dedupes_repeated_sources() -> None:
    # A resource row mirroring an own-signal derived row must not duplicate the
    # source — the union of own-signal and resource rows stays idempotent.
    dup = COLUMN_SPEC + (
        ColumnSpec("resource", "*", "app.version", "promoted", "cc_version", "TEXT", "derived"),
    )
    assert cs.derived_coalesce("metrics", dup)["cc_version"] == ["app.version", "service.version"]


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


def test_new_derived_row_populates_through_parser_with_no_parser_change(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Adding derived spec rows flows to the parser purely through derived_coalesce
    # — no _apply_promoted edit. Prove it: extend the spec, re-derive the coalesce
    # map, feed it to the parser, and the new column populates (fallback source).
    synthetic = COLUMN_SPEC + (
        ColumnSpec("metrics", "*", "x.primary", "promoted", "x_col", "TEXT", "derived"),
        ColumnSpec("metrics", "*", "x.fallback", "promoted", "x_col", "TEXT", "derived"),
    )
    coalesce = cs.derived_coalesce("metrics", synthetic)
    assert coalesce["x_col"] == ["x.primary", "x.fallback"]
    monkeypatch.setattr(parser, "METRIC_COALESCE", coalesce)
    payload = {
        "resourceMetrics": [
            {
                "resource": {"attributes": []},
                "scopeMetrics": [
                    {
                        "scope": {"name": "cc", "version": "1"},
                        "metrics": [
                            {
                                "name": "claude_code.session.count",
                                "gauge": {
                                    "dataPoints": [
                                        {
                                            "timeUnixNano": "1",
                                            "asDouble": 1.0,
                                            "attributes": _attr_list({"x.fallback": "fb"}),
                                        }
                                    ]
                                },
                            }
                        ],
                    }
                ],
            }
        ]
    }
    (row,) = parse_metrics(payload)
    assert row["x_col"] == "fb"


def test_structural_rename_breaks_the_population_guard() -> None:
    # The population guard is `table_columns(signal) <= parser keys`. Renaming a
    # structural column in the spec makes table_columns emit a literal the parser's
    # hardcoded structural extraction never produces — so the guard would fail.
    renamed = tuple(
        replace(r, column_name="ts_renamed")
        if (r.signal == "metrics" and r.column_name == "ts")
        else r
        for r in COLUMN_SPEC
    )
    payload = {
        "resourceMetrics": [
            {
                "resource": {"attributes": []},
                "scopeMetrics": [
                    {
                        "scope": {"name": "cc", "version": "1"},
                        "metrics": [
                            {
                                "name": "claude_code.session.count",
                                "gauge": {"dataPoints": [{"timeUnixNano": "1", "asDouble": 1.0}]},
                            }
                        ],
                    }
                ],
            }
        ]
    }
    keys: set[str] = set()
    for row in parse_metrics(payload):
        keys |= row.keys()
    assert "ts_renamed" in cs.table_columns("metrics", renamed)
    assert not set(cs.table_columns("metrics", renamed)) <= keys


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
