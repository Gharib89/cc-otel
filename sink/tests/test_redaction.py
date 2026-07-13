"""Redaction pass (#8): denylist, tool_parameters sweep, defense-in-depth counting."""

from __future__ import annotations

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


def test_tool_parameters_recursive_sweep_on_tool_result():
    tool_params = {
        "key": "tool_parameters",
        "value": {
            "kvlistValue": {
                "values": [
                    {"key": "full_command", "value": {"stringValue": "rm -rf /"}},
                    {"key": "file_path", "value": {"stringValue": "/etc/passwd"}},
                    {"key": "timeout", "value": {"intValue": "30"}},
                    {
                        "key": "nested",
                        "value": {
                            "kvlistValue": {
                                "values": [
                                    {"key": "bash_command", "value": {"stringValue": "x"}},
                                    {"key": "keep_me", "value": {"stringValue": "ok"}},
                                ]
                            }
                        },
                    },
                ]
            }
        },
    }
    payload = _log("tool_result", [tool_params])
    redact(payload)
    values = _record_attrs(payload)[1]["value"]["kvlistValue"]["values"]
    top_keys = {v["key"] for v in values}
    assert top_keys == {"timeout", "nested"}
    nested = next(v for v in values if v["key"] == "nested")
    nested_keys = {v["key"] for v in nested["value"]["kvlistValue"]["values"]}
    assert nested_keys == {"keep_me"}


def test_tool_parameters_not_swept_on_non_tool_event():
    # A non-tool event keeps its tool_parameters content untouched by the sweep
    # (denylist only strips top-level attribute keys, not nested kvlist entries).
    tool_params = {
        "key": "tool_parameters",
        "value": {
            "kvlistValue": {
                "values": [{"key": "full_command", "value": {"stringValue": "keep"}}]
            }
        },
    }
    payload = _log("user_prompt", [tool_params])
    redact(payload)
    values = _record_attrs(payload)[1]["value"]["kvlistValue"]["values"]
    assert {v["key"] for v in values} == {"full_command"}


def test_defense_in_depth_nonempty_counted_and_stripped():
    payload = _log(
        "user_prompt",
        [
            _attr("prompt", "my secret prompt"),
            _attr("command_name", "commit"),
        ],
    )
    result = redact(payload)
    assert result.drift_strips == 1
    assert _keys(_record_attrs(result.payload)) == {"event.name", "command_name"}


def test_defense_in_depth_empty_stripped_but_not_counted():
    payload = _log("user_prompt", [_attr("prompt", "")])
    result = redact(payload)
    assert result.drift_strips == 0
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
    assert result.drift_strips == 3
    assert _keys(_record_attrs(result.payload)) == {"event.name", "user.email", "model"}
