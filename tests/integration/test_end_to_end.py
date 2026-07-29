"""End-to-end pipeline through the HTTP layer (#22).

Drives the FastAPI sink over ``TestClient`` against a real testcontainers
Postgres — the whole path the collector exercises in production: OTLP/JSON POST →
redact → hash → transactional raw write → staging views → marts matviews. Unlike
``test_sink.py`` (which calls ``Store.write_batch`` directly) this goes through
``/v1/metrics`` and ``/v1/logs``, so redaction and the idempotency hash are
exercised where they actually run.
"""

from __future__ import annotations

import asyncio
import sys
import uuid

import psycopg
import pytest

# psycopg's async pool rejects Windows' default ProactorEventLoop; the selector
# loop is required for the app's async DB pool under TestClient locally. Linux
# (CI + production) defaults to a compatible loop, so this is a local-dev no-op.
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

from cc_otel_sink.app import create_app, get_blob  # noqa: E402
from cc_otel_sink.config import Settings  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

SESSION_ID = "3c9f0000-0000-0000-0000-000000000001"
PROMPT_ID = "3c9f0000-0000-0000-0000-0000000000ff"

# Distinctive secret values so the redaction-at-rest assertion can't false-match.
SECRET_PATH = "/home/dev/.ssh/id_rsa_SECRET"
SECRET_PROMPT = "leaked-prompt-content-SECRET"
SECRET_ERROR = "stacktrace-SECRET-xyz"


def _attr(key, value):
    return {"key": key, "value": value}


# One delta counter (claude_code.commit.count) → stg_counter_delta → fact_session_daily.
METRICS_BODY = {
    "resourceMetrics": [
        {
            "resource": {"attributes": [_attr("service.version", {"stringValue": "2.1.0"})]},
            "scopeMetrics": [
                {
                    "scope": {"name": "cc", "version": "1.0"},
                    "metrics": [
                        {
                            "name": "claude_code.commit.count",
                            "sum": {
                                "aggregationTemporality": 1,  # delta
                                "dataPoints": [
                                    {
                                        "timeUnixNano": "1700000000000000000",
                                        "asInt": "2",
                                        "attributes": [
                                            _attr("session.id", {"stringValue": SESSION_ID}),
                                            _attr("user.email", {"stringValue": "dev@corp.com"}),
                                        ],
                                    }
                                ],
                            },
                        }
                    ],
                }
            ],
        }
    ]
}


def _logs_body(*, with_denylist: bool = True) -> dict:
    """A payload with an api_request event (feeds staging/marts) and a tool_result
    event carrying redaction bait. ``with_denylist`` toggles the top-level
    ``file_path`` so two payloads that differ only by a stripped key can be hashed."""
    tool_attrs = [
        _attr("event.name", {"stringValue": "tool_result"}),
        _attr("session.id", {"stringValue": SESSION_ID}),
        _attr("tool_name", {"stringValue": "Bash"}),
        _attr("error", {"stringValue": SECRET_ERROR}),  # denylist
        _attr("prompt", {"stringValue": SECRET_PROMPT}),  # defense-in-depth → gate leak
        _attr(
            "tool_parameters",
            {
                "kvlistValue": {
                    "values": [
                        # nested bait: the whole tool_parameters attribute is denied
                        {"key": "file_path", "value": {"stringValue": SECRET_PATH}},
                        {"key": "command_name", "value": {"stringValue": "ls"}},
                    ]
                }
            },
        ),
    ]
    if with_denylist:
        tool_attrs.insert(3, _attr("file_path", {"stringValue": SECRET_PATH}))  # top-level denylist
    return {
        "resourceLogs": [
            {
                "resource": {"attributes": [_attr("service.version", {"stringValue": "2.1.0"})]},
                "scopeLogs": [
                    {
                        "scope": {"name": "cc", "version": "1.0"},
                        "logRecords": [
                            {
                                "timeUnixNano": "1700000000000000000",
                                "severityText": "INFO",
                                "body": {"stringValue": "api_request"},
                                "attributes": [
                                    _attr("event.name", {"stringValue": "api_request"}),
                                    _attr("session.id", {"stringValue": SESSION_ID}),
                                    _attr("user.email", {"stringValue": "dev@corp.com"}),
                                    _attr("model", {"stringValue": "claude-opus-4-8"}),
                                    _attr("query_source", {"stringValue": "main"}),
                                    _attr("effort", {"stringValue": "high"}),
                                    _attr("input_tokens", {"intValue": "120"}),
                                    _attr("output_tokens", {"intValue": "45"}),
                                ],
                            },
                            {
                                "timeUnixNano": "1700000000000000001",
                                "severityText": "INFO",
                                "body": {"stringValue": "tool_result"},
                                "attributes": tool_attrs,
                            },
                        ],
                    }
                ],
            }
        ]
    }


class _CaptureBlob:
    """Stand-in reservoir that records the exact bytes handed to it, so a test can
    assert the blob payload is redacted at rest without an Azure/Azurite backend
    (the app writes the same `redacted_bytes` to Postgres' hash and the blob)."""

    def __init__(self) -> None:
        self.payloads: list[bytes] = []

    def write(self, signal: str, payload: bytes) -> None:
        self.payloads.append(payload)


@pytest.fixture
def db(pg_url: str) -> str:
    """pg_url with raw tables and the idempotency ledger truncated for this test."""
    with psycopg.connect(pg_url) as c:
        c.autocommit = True
        c.execute("TRUNCATE raw.metrics, raw.events, meta.processed_batches")
    return pg_url


@pytest.fixture
def client(db: str):
    settings = Settings(
        database_url=db,
        blob_account_url=None,
        blob_connection_string=None,
        blob_container="raw",
        host="127.0.0.1",
        port=8080,
    )
    # Context manager runs the lifespan, opening a real Store pool against `db`.
    with TestClient(create_app(settings)) as c:
        yield c


def _post(client: TestClient, path: str, body: dict) -> None:
    resp = client.post(path, json=body)
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"partialSuccess": {}}


def test_end_to_end_pipeline_raw_staging_marts(client: TestClient, db: str):
    _post(client, "/v1/metrics", METRICS_BODY)
    _post(client, "/v1/logs", _logs_body())

    with psycopg.connect(db) as c:
        # raw
        metric = c.execute(
            "SELECT metric_name, value, value_kind, session_id, user_email FROM raw.metrics"
        ).fetchone()
        assert metric == (
            "claude_code.commit.count",
            2.0,
            "sum_delta",
            uuid.UUID(SESSION_ID),
            "dev@corp.com",
        )
        event_names = sorted(
            r[0] for r in c.execute("SELECT event_name FROM raw.events").fetchall()
        )
        assert event_names == ["api_request", "tool_result"]

        # staging
        (delta_row,) = c.execute(
            "SELECT metric_name, value FROM staging.stg_counter_delta"
        ).fetchall()
        assert delta_row == ("claude_code.commit.count", 2.0)
        (api_row,) = c.execute(
            "SELECT model, input_tokens, output_tokens FROM staging.stg_api_request"
        ).fetchall()
        assert api_row == ("claude-opus-4-8", 120, 45)

        # marts
        c.execute("SELECT marts.refresh_all()")
        (commits,) = c.execute(
            "SELECT commits FROM marts.fact_session_daily WHERE session_id = %s",
            (SESSION_ID,),
        ).fetchone()
        assert commits == 2
        (req_count, in_tokens) = c.execute(
            "SELECT request_count, input_tokens FROM marts.fact_api_usage "
            "WHERE session_id = %s AND model = 'claude-opus-4-8'",
            (SESSION_ID,),
        ).fetchone()
        assert (req_count, in_tokens) == (1, 120)


def test_redaction_at_rest_and_gate_leak(client: TestClient, db: str):
    before = client.get("/healthz").json()["gate_leaks"]

    _post(client, "/v1/logs", _logs_body())

    after = client.get("/healthz").json()["gate_leaks"]
    # The non-empty `prompt` defense-in-depth strip is a counted gate leak.
    assert after >= before + 1

    with psycopg.connect(db) as c:
        rows = c.execute("SELECT to_jsonb(e)::text FROM raw.events e").fetchall()
    persisted = " ".join(r[0] for r in rows)
    # Nothing secret survived to rest — denylist, defense-in-depth.
    for secret in (SECRET_PATH, SECRET_PROMPT, SECRET_ERROR):
        assert secret not in persisted


def test_idempotent_duplicate_batch(client: TestClient, db: str):
    _post(client, "/v1/metrics", METRICS_BODY)
    _post(client, "/v1/metrics", METRICS_BODY)  # replay

    with psycopg.connect(db) as c:
        (metric_count,) = c.execute("SELECT count(*) FROM raw.metrics").fetchone()
        (batch_count,) = c.execute("SELECT count(*) FROM meta.processed_batches").fetchone()
    assert metric_count == 1  # the replay inserted no second copy
    assert batch_count == 1


def test_redaction_runs_before_the_idempotency_hash(client: TestClient, db: str):
    # Two bodies that differ ONLY by a denylisted key redact to the same payload,
    # so they must hash identically — the second POST is a dedup no-op. That can
    # only hold if redaction runs before the hash on the ingest path.
    _post(client, "/v1/logs", _logs_body(with_denylist=True))
    _post(client, "/v1/logs", _logs_body(with_denylist=False))

    with psycopg.connect(db) as c:
        (event_count,) = c.execute("SELECT count(*) FROM raw.events").fetchone()
        (batch_count,) = c.execute("SELECT count(*) FROM meta.processed_batches").fetchone()
    assert event_count == 2  # both events from the first batch only
    assert batch_count == 1


# Promoted-column round-trip, folded from the retired tests/integration/test_sink.py
# (which called parse_* + Store.write_batch directly — a seam no real caller crosses).
# Exercised here through the HTTP path the collector actually uses.
ROUNDTRIP_METRICS = {
    "resourceMetrics": [
        {
            "resource": {"attributes": [_attr("service.version", {"stringValue": "2.1.0"})]},
            "scopeMetrics": [
                {
                    "scope": {"name": "cc", "version": "1.0"},
                    "metrics": [
                        {
                            "name": "claude_code.token.usage",
                            "gauge": {
                                "dataPoints": [
                                    {
                                        "timeUnixNano": "1700000000000000000",
                                        "asDouble": 42.0,
                                        "attributes": [
                                            _attr("type", {"stringValue": "input"}),
                                            _attr("model", {"stringValue": "opus"}),
                                            _attr("user.email", {"stringValue": " Dev@Corp.com "}),
                                            _attr("session.id", {"stringValue": SESSION_ID}),
                                        ],
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

ROUNDTRIP_LOGS = {
    "resourceLogs": [
        {
            "resource": {"attributes": []},
            "scopeLogs": [
                {
                    "logRecords": [
                        {
                            "timeUnixNano": "1700000000000000000",
                            "severityText": "INFO",
                            "body": {"stringValue": "api_request"},
                            "attributes": [
                                _attr("event.name", {"stringValue": "api_request"}),
                                _attr("session.id", {"stringValue": SESSION_ID}),
                                _attr("prompt.id", {"stringValue": PROMPT_ID}),
                                _attr("input_tokens", {"intValue": "120"}),
                                _attr("output_tokens", {"intValue": "45"}),
                                _attr("success", {"boolValue": True}),
                            ],
                        }
                    ]
                }
            ],
        }
    ]
}


def test_promoted_columns_round_trip_through_http(client: TestClient, db: str):
    _post(client, "/v1/metrics", ROUNDTRIP_METRICS)
    _post(client, "/v1/logs", ROUNDTRIP_LOGS)

    with psycopg.connect(db) as c:
        metric_row = c.execute(
            "SELECT metric_name, value, value_kind, type_label, model, user_email, "
            "session_id, cc_version, scope_name FROM raw.metrics"
        ).fetchone()
        event_row = c.execute(
            "SELECT event_name, input_tokens, output_tokens, success_bool, "
            "session_id, prompt_id, body FROM raw.events"
        ).fetchone()

    # user_email normalized (trim + lowercase); session/prompt ids coerced to UUID.
    assert metric_row == (
        "claude_code.token.usage",
        42.0,
        "gauge_last",
        "input",
        "opus",
        "dev@corp.com",
        uuid.UUID(SESSION_ID),
        "2.1.0",
        "cc",
    )
    assert event_row == (
        "api_request",
        120,
        45,
        True,
        uuid.UUID(SESSION_ID),
        uuid.UUID(PROMPT_ID),
        "api_request",
    )


def test_redaction_at_rest_in_blob_reservoir_payload(db: str):
    # The other at-rest store (ADR-0005): assert the bytes the app hands the blob
    # reservoir carry no secrets. A capturing fake stands in for Azure so the check
    # runs with no cloud backend.
    settings = Settings(
        database_url=db,
        blob_account_url=None,
        blob_connection_string=None,
        blob_container="raw",
        host="127.0.0.1",
        port=8080,
    )
    app = create_app(settings)
    capture = _CaptureBlob()
    app.dependency_overrides[get_blob] = lambda: capture
    with TestClient(app) as c:
        _post(c, "/v1/logs", _logs_body())

    assert capture.payloads, "expected a blob write to be scheduled"
    reservoir = b" ".join(capture.payloads).decode()
    for secret in (SECRET_PATH, SECRET_PROMPT, SECRET_ERROR):
        assert secret not in reservoir
