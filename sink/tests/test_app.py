"""Endpoint behavior (#7): write-before-200, duplicate no-op, failed-write 5xx."""

from __future__ import annotations

import gzip
import json

import pytest
from cc_otel_sink import counters
from cc_otel_sink.app import create_app, get_blob, get_store
from cc_otel_sink.config import Settings
from fastapi.testclient import TestClient

SETTINGS = Settings(
    database_url="",
    blob_account_url=None,
    blob_connection_string=None,
    blob_container="raw",
    host="127.0.0.1",
    port=8080,
)

METRICS_BODY = {
    "resourceMetrics": [
        {
            "resource": {"attributes": []},
            "scopeMetrics": [
                {
                    "metrics": [
                        {
                            "name": "claude_code.token.usage",
                            "gauge": {
                                "dataPoints": [
                                    {
                                        "timeUnixNano": "1700000000000000000",
                                        "asDouble": 1.0,
                                        "attributes": [
                                            {"key": "model", "value": {"stringValue": "opus"}},
                                            {
                                                "key": "file_path",
                                                "value": {"stringValue": "/secret"},
                                            },
                                        ],
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


class FakeStore:
    def __init__(self, result: bool = True, error: Exception | None = None) -> None:
        self.calls: list[tuple] = []
        self.result = result
        self.error = error

    async def write_batch(self, metrics, events, batch_hash):
        self.calls.append((metrics, events, batch_hash))
        if self.error is not None:
            raise self.error
        return self.result


class FakeBlob:
    def __init__(self) -> None:
        self.writes: list[tuple[str, bytes]] = []

    def write(self, signal: str, payload: bytes) -> None:
        self.writes.append((signal, payload))


@pytest.fixture(autouse=True)
def _reset_counters():
    counters.reset()
    yield
    counters.reset()


def _client(store: FakeStore, blob: FakeBlob | None = None) -> TestClient:
    app = create_app(SETTINGS)
    app.dependency_overrides[get_store] = lambda: store
    app.dependency_overrides[get_blob] = lambda: blob
    return TestClient(app)


def test_metrics_write_returns_200_and_passes_rows_to_store():
    store = FakeStore()
    with _client(store) as client:
        resp = client.post("/v1/metrics", json=METRICS_BODY)
    assert resp.status_code == 200
    assert len(store.calls) == 1
    metrics, events, batch_hash = store.calls[0]
    assert len(metrics) == 1
    assert events == []
    assert len(batch_hash) == 64  # sha256 hex


def test_gzip_encoded_body_is_decompressed():
    store = FakeStore()
    body = gzip.compress(json.dumps(METRICS_BODY).encode())
    with _client(store) as client:
        resp = client.post(
            "/v1/metrics", content=body, headers={"Content-Encoding": "gzip"}
        )
    assert resp.status_code == 200
    assert len(store.calls) == 1


def test_redaction_runs_before_store_and_counts_drift():
    # file_path (denylist) is stripped silently; prompt (defense-in-depth) is
    # counted. Both must be gone from what the store receives.
    body = {
        "resourceLogs": [
            {
                "resource": {"attributes": []},
                "scopeLogs": [
                    {
                        "logRecords": [
                            {
                                "timeUnixNano": "1700000000000000000",
                                "attributes": [
                                    {"key": "event.name", "value": {"stringValue": "user_prompt"}},
                                    {"key": "prompt", "value": {"stringValue": "secret"}},
                                    {"key": "file_path", "value": {"stringValue": "/x"}},
                                    {"key": "command_name", "value": {"stringValue": "commit"}},
                                ],
                            }
                        ]
                    }
                ],
            }
        ]
    }
    store = FakeStore()
    with _client(store) as client:
        resp = client.post("/v1/logs", json=body)
        health = client.get("/healthz").json()
    assert resp.status_code == 200
    _, events, _ = store.calls[0]
    (row,) = events
    assert row["command_name"] == "commit"
    assert health["gate_leaks"] == 1


def test_duplicate_batch_is_noop_200():
    store = FakeStore(result=False)  # hash already in processed_batches
    with _client(store) as client:
        resp = client.post("/v1/metrics", json=METRICS_BODY)
    assert resp.status_code == 200
    assert len(store.calls) == 1


def test_failed_write_returns_503():
    store = FakeStore(error=RuntimeError("db down"))
    with _client(store) as client:
        resp = client.post("/v1/metrics", json=METRICS_BODY)
    assert resp.status_code == 503


def test_invalid_json_returns_400():
    store = FakeStore()
    with _client(store) as client:
        resp = client.post("/v1/metrics", content=b"not json")
    assert resp.status_code == 400
    assert store.calls == []


def test_blob_write_scheduled_after_response():
    store = FakeStore()
    blob = FakeBlob()
    with _client(store, blob) as client:
        resp = client.post("/v1/metrics", json=METRICS_BODY)
    assert resp.status_code == 200
    assert len(blob.writes) == 1
    signal, payload = blob.writes[0]
    assert signal == "metrics"
    # Blob content is redacted: the stripped file_path must not appear.
    assert b"file_path" not in payload


def test_duplicate_batch_still_writes_blob():
    # Blob write is best-effort and independent of the idempotency outcome.
    store = FakeStore(result=False)
    blob = FakeBlob()
    with _client(store, blob) as client:
        resp = client.post("/v1/metrics", json=METRICS_BODY)
    assert resp.status_code == 200
    assert len(blob.writes) == 1


def test_healthz():
    store = FakeStore()
    with _client(store) as client:
        resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
