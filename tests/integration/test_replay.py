"""Replay plan/apply through the in-process sink (#267).

Drives ``tools.replay.plan`` -> ``apply`` against a real testcontainers Postgres
with the FastAPI sink mounted in-process (``httpx.ASGITransport`` via
``TestClient``). The load-bearing invariant under test: ``apply`` clears
``meta.processed_batches`` for the window *before* re-POSTing, so the sink's
idempotency guard doesn't no-op the replay (the ``replay.py`` module docstring,
now an assertion rather than a comment).
"""

from __future__ import annotations

import asyncio
import gzip
import sys
import uuid
from datetime import UTC, date, datetime

import psycopg
import pytest

# psycopg's async pool rejects Windows' default ProactorEventLoop under TestClient;
# the selector loop is required locally (Linux CI defaults to a compatible loop).
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

from cc_otel_sink.app import create_app, prepare_batch  # noqa: E402
from cc_otel_sink.config import Settings  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from tools._window import partition_prefix  # noqa: E402
from tools.replay import apply, plan  # noqa: E402

_DAY = date(2026, 7, 20)
_SIGNALS = ("logs",)


def _attr(key: str, value: dict) -> dict:
    return {"key": key, "value": value}


def _logs_payload(session: str) -> dict:
    """One api_request log record with ``event_time`` inside the window."""
    nano = str(int(datetime(2026, 7, 20, 12, tzinfo=UTC).timestamp()) * 1_000_000_000)
    return {
        "resourceLogs": [
            {
                "resource": {"attributes": [_attr("service.version", {"stringValue": "2.1.0"})]},
                "scopeLogs": [
                    {
                        "scope": {"name": "cc", "version": "1.0"},
                        "logRecords": [
                            {
                                "timeUnixNano": nano,
                                "severityText": "INFO",
                                "body": {"stringValue": "api_request"},
                                "attributes": [
                                    _attr("event.name", {"stringValue": "api_request"}),
                                    _attr("session.id", {"stringValue": session}),
                                    _attr("user.email", {"stringValue": "dev@corp.com"}),
                                    _attr("input_tokens", {"intValue": "120"}),
                                ],
                            }
                        ],
                    }
                ],
            }
        ]
    }


class _FakeReservoir:
    """Dict-backed reservoir: ``plan`` lists + hashes, ``apply`` re-downloads per POST."""

    def __init__(self, blobs: dict[str, bytes]) -> None:
        self.blobs = blobs

    def list_names(self, prefix: str) -> list[str]:
        return sorted(name for name in self.blobs if name.startswith(prefix))

    def download(self, name: str) -> bytes:
        return self.blobs[name]


@pytest.fixture
def db(pg_url: str) -> str:
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
    with TestClient(create_app(settings)) as c:
        yield c


def _blob_for(session: str) -> tuple[bytes, str]:
    """Return (gzip blob, batch hash) built exactly as the sink stores it — the blob
    content is the canonical redacted bytes, so its hash matches the sink's on re-POST."""
    batch = prepare_batch(_logs_payload(session), "logs")
    return gzip.compress(batch.canonical_bytes), batch.batch_hash


def _events(conn: psycopg.Connection) -> list[tuple]:
    return conn.execute(
        "SELECT event_name, session_id FROM raw.events ORDER BY event_time"
    ).fetchall()


def test_apply_rebuilds_window_rows_via_repost(client: TestClient, db: str):
    session = "3c9f0000-0000-0000-0000-000000000267"
    blob, batch_hash = _blob_for(session)
    name = partition_prefix("logs", _DAY) + "120000-abc.json.gz"
    reservoir = _FakeReservoir({name: blob})

    with psycopg.connect(db) as conn:
        conn.autocommit = True
        # An out-of-window row that must survive, and a stale in-window row to be deleted.
        conn.execute(
            "INSERT INTO raw.events (event_time, event_name) VALUES (%s, %s)",
            (datetime(2026, 7, 1, tzinfo=UTC), "outside_window"),
        )
        conn.execute(
            "INSERT INTO raw.events (event_time, event_name) VALUES (%s, %s)",
            (datetime(2026, 7, 20, 9, tzinfo=UTC), "stale_in_window"),
        )
        # Pre-seed the ledger so a *naive* re-POST would no-op — apply must clear it first.
        conn.execute("INSERT INTO meta.processed_batches (batch_hash) VALUES (%s)", (batch_hash,))

        the_plan = plan(conn, reservoir, _SIGNALS, [_DAY])
        assert the_plan.hashes == [batch_hash]
        assert the_plan.row_counts == {"events": 1}  # the stale in-window row

        apply(conn, reservoir, client, the_plan)

        # The out-of-window row survived; the stale in-window row was replaced by the
        # re-POST's api_request row — proof the ledger clear preceded the re-POST.
        assert _events(conn) == [
            ("outside_window", None),
            ("api_request", uuid.UUID(session)),
        ]
        # Ledger hash absent-then-repopulated by the sink's own idempotency write.
        (ledger_count,) = conn.execute(
            "SELECT count(*) FROM meta.processed_batches WHERE batch_hash = %s", (batch_hash,)
        ).fetchone()
        assert ledger_count == 1


def test_plan_is_non_destructive(db: str):
    """Dry-run reaches ``plan`` but not ``apply``: nothing is deleted or re-POSTed."""
    session = "3c9f0000-0000-0000-0000-0000000002aa"
    blob, batch_hash = _blob_for(session)
    name = partition_prefix("logs", _DAY) + "120000-def.json.gz"
    reservoir = _FakeReservoir({name: blob})

    with psycopg.connect(db) as conn:
        conn.autocommit = True
        conn.execute(
            "INSERT INTO raw.events (event_time, event_name) VALUES (%s, %s)",
            (datetime(2026, 7, 20, 9, tzinfo=UTC), "stale_in_window"),
        )
        conn.execute("INSERT INTO meta.processed_batches (batch_hash) VALUES (%s)", (batch_hash,))

        plan(conn, reservoir, _SIGNALS, [_DAY])

        # plan() touched nothing.
        assert _events(conn) == [("stale_in_window", None)]
        (ledger_count,) = conn.execute("SELECT count(*) FROM meta.processed_batches").fetchone()
        assert ledger_count == 1
