"""Shared reservoir access for the analysis notebooks (#249).

Thin plumbing only: read a blob window into decoded OTLP payloads over DuckDB,
reusing the ``tools/`` sweep helpers (``configure_duckdb`` for the Azure secret,
``globs`` for the Hive-partition addressing). Analysis logic lives in the
notebooks; this stays free of it so it can be unit-tested without a live
reservoir.
"""

from __future__ import annotations

import json
from datetime import date
from typing import TYPE_CHECKING, Any

import duckdb

from tools._window import globs

if TYPE_CHECKING:
    from duckdb import DuckDBPyConnection


def read_payloads(
    con: DuckDBPyConnection,
    container: str,
    signals: tuple[str, ...],
    days: list[date],
) -> list[dict[str, Any]]:
    """Decode every blob in the ``signals`` x ``days`` window into OTLP payload dicts.

    One ``read_json_objects`` call per partition glob (mirrors ``tools.sweep``); an
    empty partition (DuckDB "no files found") contributes nothing, while any other
    ``IOException`` — a real read/credential failure — propagates rather than
    silently yielding a short read.
    """
    payloads: list[dict[str, Any]] = []
    for target in globs(container, signals, days):
        escaped = target.replace("'", "''")
        try:
            rows = con.execute(
                f"SELECT json FROM read_json_objects('{escaped}', format='unstructured')"
            ).fetchall()
        except duckdb.IOException as err:
            if "no files found" not in str(err).lower():
                raise
            rows = []
        payloads.extend(json.loads(text) for (text,) in rows)
    return payloads
