"""Redaction pass (#8): denylist, defense-in-depth counting."""

from __future__ import annotations

import pytest
from cc_otel_sink.redaction import redact


def _attr(key: str, string: str) -> dict:
    return {"key": key, "value": {"stringValue": string}}


def _log(event_name: str, attributes: list[dict]) -> dict:
    attrs = [_attr("event.name", event_name), *attributes]
    return {
        "resourceLogs": [
            {
                "resource": {"attributes": []},
                "scopeLogs": [{"logRecords": [{"attributes": attrs}]}],
            }
        ]
    }


def _record_attrs(payload: dict) -> list[dict]:
    return payload["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]["attributes"]


def _keys(attributes: list[dict]) -> set[str]:
    return {a["key"] for a in attributes}


def test_denylist_stripped_from_log_attributes():
    payload = _log(
        "tool_decision",
        [
            _attr("full_command", "rm -rf /"),
            _attr("bash_command", "cat secret"),
            _attr("file_path", "/home/x/.ssh/id_rsa"),
            _attr("error", "stack trace with paths"),
            _attr("tool_name", "Bash"),
        ],
    )
    result = redact(payload)
    keys = _keys(_record_attrs(result.payload))
    assert keys == {"event.name", "tool_name"}


def test_denylist_stripped_from_metric_datapoint_attributes():
    payload = {
        "resourceMetrics": [
            {
                "resource": {"attributes": [_attr("file_path", "/secret")]},
                "scopeMetrics": [
                    {
                        "metrics": [
                            {
                                "name": "claude_code.token.usage",
                                "gauge": {
                                    "dataPoints": [
                                        {
                                            "attributes": [
                                                _attr("error", "boom"),
                                                _attr("model", "opus"),
                                            ]
                                        }
                                    ]
                                },
                            }
                        ]
                    }
                ],
            }
        ]
    }
    redact(payload)
    res_attrs = payload["resourceMetrics"][0]["resource"]["attributes"]
    dp_attrs = payload["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]["gauge"][
        "dataPoints"
    ][0]["attributes"]
    assert _keys(res_attrs) == set()
    assert _keys(dp_attrs) == {"model"}


@pytest.mark.parametrize(
    "event_name",
    ["tool_result", "tool_decision", "claude_code.tool_result", "claude_code.tool_decision"],
)
def test_tool_payload_keys_stripped_from_json_string_shape(event_name):
    # The shape the fleet actually emits (#369): tool_parameters / tool_input arrive
    # as a JSON *stringValue*, not a nested kvlist. The predecessor sweep only
    # descended kvlistValue, so it stripped nothing while full command lines and
    # absolute paths landed at rest. The deny is on the whole attribute, so the
    # payload's shape can no longer decide whether redaction happens.
    payload = _log(
        event_name,
        [
            _attr("tool_parameters", '{"bash_command":"cat","full_command":"cat ~/.ssh/id_rsa"}'),
            _attr("tool_input", '{"file_path":"e:\\\\POCs\\\\itworx\\\\secrets.json"}'),
            _attr("tool_name", "Bash"),
        ],
    )
    result = redact(payload)
    assert _keys(_record_attrs(result.payload)) == {"event.name", "tool_name"}


def test_tool_payload_keys_stripped_from_nested_kvlist_shape():
    # The other emission shape: a nested kvlist. Denied wholesale too, so no leaf
    # survives — the predecessor swept named leaves and kept the rest of the args.
    tool_params = {
        "key": "tool_parameters",
        "value": {
            "kvlistValue": {
                "values": [
                    {"key": "full_command", "value": {"stringValue": "rm -rf /"}},
                    {"key": "timeout", "value": {"intValue": "30"}},
                ]
            }
        },
    }
    payload = _log("tool_result", [tool_params, _attr("tool_name", "Bash")])
    result = redact(payload)
    assert _keys(_record_attrs(result.payload)) == {"event.name", "tool_name"}


def test_tool_payload_keys_stripped_on_a_non_tool_event():
    # The deny is signal-blind (denylist() carries no signal), so the keys go
    # wherever they appear — not only on tool_result / tool_decision, which is
    # all the predecessor's tool-event gate reached.
    payload = _log("user_prompt", [_attr("tool_parameters", '{"full_command":"keep"}')])
    result = redact(payload)
    assert _keys(_record_attrs(result.payload)) == {"event.name"}


def test_defense_in_depth_nonempty_counted_and_stripped():
    payload = _log(
        "user_prompt",
        [
            _attr("prompt", "my secret prompt"),
            _attr("command_name", "commit"),
        ],
    )
    result = redact(payload)
    assert result.gate_leaks == 1
    assert _keys(_record_attrs(result.payload)) == {"event.name", "command_name"}


def test_defense_in_depth_empty_stripped_but_not_counted():
    payload = _log("user_prompt", [_attr("prompt", "")])
    result = redact(payload)
    assert result.gate_leaks == 0
    assert _keys(_record_attrs(result.payload)) == {"event.name"}


def test_defense_in_depth_all_keys_and_kept_survivors():
    payload = _log(
        "api_request_body",
        [
            _attr("body", "raw request json"),
            _attr("body_ref", "blob://x"),
            _attr("response", "raw response"),
            _attr("user.email", "Dev@Corp.com"),
            _attr("model", "opus"),
        ],
    )
    result = redact(payload)
    assert result.gate_leaks == 3
    assert _keys(_record_attrs(result.payload)) == {"event.name", "user.email", "model"}
