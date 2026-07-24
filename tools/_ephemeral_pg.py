"""Throwaway-Postgres provisioning shared by ``spec_sync`` and ``matview_sync`` (#275).

Both ``--check`` gates self-provision a fully-migrated ``postgres:16`` when no
``DATABASE_URL`` is supplied. This module holds that logic for both tools in one
place; each tool passes its own container name (so parallel runs don't collide)
and its migrations dir (passed at call time so the tools' monkeypatchable
``_MIGRATIONS_DIR`` still drives the ephemeral path).
"""

from __future__ import annotations

import subprocess
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import psycopg


def _up_section(sql: str) -> str:
    return sql.split("-- migrate:up", 1)[1].split("-- migrate:down", 1)[0]


def _apply_migrations(conn: psycopg.Connection, migrations_dir: Path) -> None:
    conn.autocommit = True
    for path in sorted(migrations_dir.glob("*.sql")):
        up = _up_section(path.read_text(encoding="utf-8")).strip()
        if up:
            conn.execute(up)  # type: ignore[arg-type]


@contextmanager
def ephemeral_db(container_name: str, migrations_dir: Path) -> Iterator[psycopg.Connection]:
    """Spin a throwaway ``postgres:16``, apply every migration, yield a connection."""
    subprocess.run(["docker", "rm", "-f", container_name], capture_output=True, check=False)
    subprocess.run(
        [
            "docker",
            "run",
            "-d",
            "--name",
            container_name,
            "-e",
            "POSTGRES_USER=postgres",
            "-e",
            "POSTGRES_PASSWORD=postgres",
            "-e",
            "POSTGRES_DB=cc_otel",
            "-p",
            "127.0.0.1::5432",
            "postgres:16",
        ],
        check=True,
        capture_output=True,
    )
    try:
        port = (
            subprocess.run(
                ["docker", "port", container_name, "5432"],
                check=True,
                capture_output=True,
                text=True,
            )
            .stdout.strip()
            .rsplit(":", 1)[-1]
        )
        url = f"postgres://postgres:postgres@127.0.0.1:{port}/cc_otel?sslmode=disable"
        conn = None
        for _ in range(30):
            try:
                conn = psycopg.connect(url)
                break
            except psycopg.OperationalError:
                time.sleep(1)
        if conn is None:
            raise RuntimeError("ephemeral Postgres did not become ready within 30s")
        with conn:
            _apply_migrations(conn, migrations_dir)
            yield conn
    finally:
        subprocess.run(["docker", "rm", "-f", container_name], capture_output=True, check=False)


@contextmanager
def connection(
    database_url: str | None, container_name: str, migrations_dir: Path
) -> Iterator[psycopg.Connection]:
    if database_url:
        with psycopg.connect(database_url) as conn:
            yield conn
    else:
        with ephemeral_db(container_name, migrations_dir) as conn:
            yield conn
