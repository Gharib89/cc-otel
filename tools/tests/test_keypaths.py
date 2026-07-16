from tools._keypaths import extract_key_paths


def _attr(key, val="x"):
    return {"key": key, "value": {"stringValue": val}}


def test_metrics_payload_datapoint_and_resource_attrs():
    payload = {
        "resourceMetrics": [
            {
                "resource": {"attributes": [_attr("service.name", "claude-code")]},
                "scopeMetrics": [
                    {
                        "scope": {"name": "cc"},
                        "metrics": [
                            {
                                "name": "claude_code.token.usage",
                                "sum": {
                                    "dataPoints": [{"attributes": [_attr("type"), _attr("model")]}]
                                },
                            }
                        ],
                    }
                ],
            }
        ]
    }
    assert extract_key_paths(payload) == {
        ("resource", "*", "service.name"),
        ("metrics", "claude_code.token.usage", "type"),
        ("metrics", "claude_code.token.usage", "model"),
    }


def test_logs_payload_uses_event_name_and_maps_to_events_signal():
    payload = {
        "resourceLogs": [
            {
                "resource": {"attributes": [_attr("os.type", "linux")]},
                "scopeLogs": [
                    {
                        "logRecords": [
                            {"attributes": [_attr("event.name", "api_request"), _attr("model")]}
                        ]
                    }
                ],
            }
        ]
    }
    assert extract_key_paths(payload) == {
        ("resource", "*", "os.type"),
        ("events", "api_request", "event.name"),
        ("events", "api_request", "model"),
    }


def test_all_metric_kinds_are_walked():
    payload = {
        "resourceMetrics": [
            {
                "scopeMetrics": [
                    {
                        "metrics": [
                            {"name": "g", "gauge": {"dataPoints": [{"attributes": [_attr("a")]}]}},
                            {
                                "name": "h",
                                "histogram": {"dataPoints": [{"attributes": [_attr("b")]}]},
                            },
                        ]
                    }
                ]
            }
        ]
    }
    assert extract_key_paths(payload) == {("metrics", "g", "a"), ("metrics", "h", "b")}


def test_unknown_shape_yields_empty_set():
    assert extract_key_paths({"resourceSpans": [{}]}) == set()
