"""Integration-test harness for the DB star schema (#19).

Spins up a throwaway Postgres 16 (testcontainers — never the shared dev DB, per
CLAUDE.md), applies every dbmate migration in order, and hands tests a live
connection. Migrations are applied by executing each file's `migrate:up` section
directly, so CI needs no dbmate binary — only Docker.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

# The `with PostgresContainer(...)` context already stops the container, so the Ryuk
# reaper is redundant here — disabling it drops a dependency and speeds startup.
os.environ.setdefault("TESTCONTAINERS_RYUK_DISABLED", "true")

import psycopg  # noqa: E402
import pytest  # noqa: E402
from testcontainers.postgres import PostgresContainer  # noqa: E402

MIGRATIONS_DIR = Path(__file__).resolve().parents[2] / "db" / "migrations"


def _up_section(sql: str) -> str:
    """Return the SQL between `-- migrate:up` and `-- migrate:down`."""
    up = sql.split("-- migrate:up", 1)[1]
    up = up.split("-- migrate:down", 1)[0]
    # Drop a leading `transaction:false` directive if present (irrelevant here —
    # we apply each section in its own autocommit statement).
    return re.sub(r"^\s*transaction:false\s*", "", up, count=1)


def _apply_migrations(conn: psycopg.Connection) -> None:
    conn.autocommit = True
    for path in sorted(MIGRATIONS_DIR.glob("*.sql")):
        up = _up_section(path.read_text(encoding="utf-8")).strip()
        if up:
            conn.execute(up)


@pytest.fixture(scope="session")
def pg_url() -> str:
    with PostgresContainer("postgres:16", driver="psycopg") as pg:
        # Force IPv4: the container maps to 0.0.0.0, but `localhost` can resolve to
        # IPv6 (::1) first and hang on Docker Desktop for Windows.
        url = pg.get_connection_url(driver=None).replace("localhost", "127.0.0.1")
        with psycopg.connect(url) as conn:
            _apply_migrations(conn)
        yield url


@pytest.fixture
def conn(pg_url: str):
    """Fresh connection with raw tables truncated — each test owns its fixtures."""
    with psycopg.connect(pg_url) as c:
        c.autocommit = True
        c.execute("TRUNCATE raw.metrics, raw.events, marts.mart_refresh_log, marts.dq_finding")
        yield c
