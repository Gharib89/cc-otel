"""Row-insert helpers for the integration fixtures."""

from __future__ import annotations


def _insert(conn, table: str, **cols) -> None:
    names = ",".join(cols)
    placeholders = ",".join(["%s"] * len(cols))
    conn.execute(f"INSERT INTO {table} ({names}) VALUES ({placeholders})", list(cols.values()))


def ins_metric(conn, **cols) -> None:
    _insert(conn, "raw.metrics", **cols)


def ins_event(conn, **cols) -> None:
    _insert(conn, "raw.events", **cols)
