"""Parser (#16 promoted columns, #6 identity): OTLP/JSON → raw rows."""

from __future__ import annotations

from datetime import UTC, datetime

import pytest
from cc_otel_sink.parser import normalize_email, parse_events, parse_metrics


def _attr(key: str, value: dict) -> dict:
    return {"key": key, "value": value}


def _s(v: str) -> dict:
    return {"stringValue": v}


def _i(v: int) -> dict:
    return {"intValue": str(v)}


# --- email normalization (#6) ---------------------------------------------


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("  Dev@Corp.COM ", "dev@corp.com"),
        ("dev@corp.com", "dev@corp.com"),
        ("", None),
        ("   ", None),
        (None, None),
        (123, None),
    ],
)
def test_normalize_email(raw, expected):
    assert normalize_email(raw) == expected


# --- metrics ---------------------------------------------------------------


def _metric_payload(metric: dict, res_attrs: list[dict] | None = None) -> dict:
    return {
        "resourceMetrics": [
            {
                "resource": {"attributes": res_attrs or []},
                "scopeMetrics": [{"scope": {"name": "cc", "version": "1.0"}, "metrics": [metric]}],
            }
        ]
    }


def test_gauge_metric_promotes_columns_and_normalizes_email():
    payload = _metric_payload(
        {
            "name": "claude_code.token.usage",
            "gauge": {
                "dataPoints": [
                    {
                        "timeUnixNano": "1700000000123456000",
                        "asDouble": 42.5,
                        "attributes": [
                            _attr("type", _s("input")),
                            _attr("model", _s("opus")),
                            _attr("user.email", _s("  Dev@Corp.com ")),
                            _attr("session.id", _s("2b8f0000-0000-0000-0000-000000000001")),
                        ],
                    }
                ]
            },
        }
    )
    (row,) = parse_metrics(payload)
    assert row["metric_name"] == "claude_code.token.usage"
    assert row["metric_type"] == "gauge"
    assert row["value_kind"] == "gauge_last"
    assert row["value"] == 42.5
    assert row["type_label"] == "input"
    assert row["model"] == "opus"
    assert row["user_email"] == "dev@corp.com"
    assert row["session_id"] == "2b8f0000-0000-0000-0000-000000000001"
    assert row["scope_name"] == "cc"
    assert row["ts"] == datetime(2023, 11, 14, 22, 13, 20, 123456, tzinfo=UTC)


def test_account_id_and_cc_version_coalesce():
    payload = _metric_payload(
        {
            "name": "claude_code.session.count",
            "sum": {
                "aggregationTemporality": 1,
                "dataPoints": [
                    {
                        "timeUnixNano": "1700000000000000000",
                        "asInt": "3",
                        "attributes": [
                            _attr("user.account_id", _s("acct-legacy")),
                            _attr("user.account_uuid", _s("acct-uuid")),
                        ],
                    }
                ],
            },
        },
        res_attrs=[_attr("service.version", _s("2.1.0"))],
    )
    (row,) = parse_metrics(payload)
    assert row["value_kind"] == "sum_delta"
    assert row["value"] == 3.0
    # account_uuid wins over account_id.
    assert row["user_account_id"] == "acct-uuid"
    # cc_version falls back to resource service.version when app.version absent.
    assert row["cc_version"] == "2.1.0"


def test_app_version_beats_resource_version():
    payload = _metric_payload(
        {
            "name": "claude_code.session.count",
            "sum": {
                "aggregationTemporality": 2,
                "dataPoints": [
                    {
                        "timeUnixNano": "1700000000000000000",
                        "asInt": "1",
                        "attributes": [_attr("app.version", _s("9.9.9"))],
                    }
                ],
            },
        },
        res_attrs=[_attr("service.version", _s("2.1.0"))],
    )
    (row,) = parse_metrics(payload)
    assert row["value_kind"] == "sum_cumulative"
    assert row["cc_version"] == "9.9.9"


def test_histogram_metric_uses_sum_and_count():
    payload = _metric_payload(
        {
            "name": "claude_code.some.histogram",
            "histogram": {
                "dataPoints": [{"timeUnixNano": "1700000000000000000", "sum": 12.0, "count": "7"}]
            },
        }
    )
    (row,) = parse_metrics(payload)
    assert row["metric_type"] == "histogram"
    assert row["value_kind"] == "hist_sum"
    assert row["value"] == 12.0
    assert row["count"] == 7


# --- events ----------------------------------------------------------------


def test_event_row_promotes_columns_and_coerces_types():
    payload = {
        "resourceLogs": [
            {
                "resource": {"attributes": [_attr("service.version", _s("2.1.0"))]},
                "scopeLogs": [
                    {
                        "scope": {"name": "cc", "version": "1.0"},
                        "logRecords": [
                            {
                                "timeUnixNano": "1700000000000000000",
                                "severityText": "INFO",
                                "severityNumber": 9,
                                "body": {"stringValue": "api_request"},
                                "attributes": [
                                    _attr("event.name", _s("api_request")),
                                    _attr("input_tokens", _i(120)),
                                    _attr("output_tokens", _i(45)),
                                    _attr("user.email", _s("A@B.com")),
                                    _attr("model", _s("opus")),
                                ],
                            }
                        ],
                    }
                ],
            }
        ]
    }
    (row,) = parse_events(payload)
    assert row["event_name"] == "api_request"
    assert row["severity"] == "INFO"
    assert row["severity_number"] == 9
    assert row["body"] == "api_request"
    assert row["input_tokens"] == 120
    assert row["output_tokens"] == 45
    assert row["user_email"] == "a@b.com"
    assert row["cc_version"] == "2.1.0"
    assert row["event_time"] == datetime(2023, 11, 14, 22, 13, 20, tzinfo=UTC)


def test_event_name_strips_claude_code_prefix():
    payload = {
        "resourceLogs": [
            {
                "resource": {"attributes": []},
                "scopeLogs": [
                    {
                        "logRecords": [
                            {
                                "timeUnixNano": "1700000000000000000",
                                "attributes": [
                                    _attr("event.name", _s("claude_code.api_request")),
                                ],
                            }
                        ]
                    }
                ],
            }
        ]
    }
    (row,) = parse_events(payload)
    assert row["event_name"] == "api_request"


def test_event_success_bool_coercion():
    payload = {
        "resourceLogs": [
            {
                "resource": {"attributes": []},
                "scopeLogs": [
                    {
                        "logRecords": [
                            {
                                "timeUnixNano": "1700000000000000000",
                                "attributes": [
                                    _attr("event.name", _s("tool_result")),
                                    _attr("success", {"boolValue": True}),
                                ],
                            }
                        ]
                    }
                ],
            }
        ]
    }
    (row,) = parse_events(payload)
    assert row["success_bool"] is True
