"""End-to-end sink write path against a real Postgres (#7): the parser's promoted
columns match the raw DDL, writes are transactional, and a replayed batch is a
no-op."""

from __future__ import annotations

import asyncio
import sys
import uuid

import psycopg
import pytest
import pytest_asyncio

# psycopg's async pool rejects Windows' default ProactorEventLoop; the selector
# loop is required for async DB work locally. Production runs on Linux, whose
# default loop is already compatible, so this guard is a local-dev-only no-op there.
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

from cc_otel_sink.parser import parse_events, parse_metrics
from cc_otel_sink.store import Store

SESSION_ID = "2b8f0000-0000-0000-0000-000000000001"
PROMPT_ID = "2b8f0000-0000-0000-0000-0000000000ff"


def _attr(key, value):
    return {"key": key, "value": value}


METRICS_PAYLOAD = {
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

LOGS_PAYLOAD = {
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


@pytest.fixture
def clean_db(pg_url: str) -> str:
    with psycopg.connect(pg_url) as c:
        c.autocommit = True
        c.execute("TRUNCATE raw.metrics, raw.events, meta.processed_batches")
    return pg_url


@pytest_asyncio.fixture
async def store(clean_db: str):
    s = Store.from_dsn(clean_db)
    await s.open()
    try:
        yield s
    finally:
        await s.close()


async def test_write_batch_persists_promoted_columns(store: Store, clean_db: str):
    metrics = parse_metrics(METRICS_PAYLOAD)
    events = parse_events(LOGS_PAYLOAD)

    written = await store.write_batch(metrics, events, "batch-hash-1")
    assert written is True

    with psycopg.connect(clean_db) as c:
        metric_row = c.execute(
            "SELECT metric_name, value, value_kind, type_label, model, user_email, "
            "session_id, cc_version, scope_name FROM raw.metrics"
        ).fetchone()
        event_row = c.execute(
            "SELECT event_name, input_tokens, output_tokens, success_bool, "
            "session_id, prompt_id, body FROM raw.events"
        ).fetchone()
        (batches,) = c.execute("SELECT count(*) FROM meta.processed_batches").fetchone()

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
    assert batches == 1


async def test_replayed_batch_is_noop(store: Store, clean_db: str):
    metrics = parse_metrics(METRICS_PAYLOAD)

    assert await store.write_batch(metrics, [], "dup-hash") is True
    assert await store.write_batch(metrics, [], "dup-hash") is False

    with psycopg.connect(clean_db) as c:
        (metric_count,) = c.execute("SELECT count(*) FROM raw.metrics").fetchone()
        (batch_count,) = c.execute("SELECT count(*) FROM meta.processed_batches").fetchone()

    # The replay inserted no second copy.
    assert metric_count == 1
    assert batch_count == 1
