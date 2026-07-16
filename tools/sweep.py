"""Sweep a recent blob window and report key paths not yet in the column registry.

Reads the Hive-partitioned reservoir with DuckDB (``read_json_objects`` over
``azure://``), extracts every attribute key path (``tools._keypaths``), and diffs
against ``meta.column_registry`` (``tools._registry``). Reports two buckets:

* **Unclassified** — keys with no registry row; each must be classified
  promoted/kept/denied in a migration (see docs/agents/column-curation.md).
* **Redaction leaks** — keys classified ``denied`` yet present in the redacted blob;
  a leak means the sink's redaction missed one (#8).

Manual / on-demand — never wired into CI or the sink. Requires ``DATABASE_URL`` and the
``CC_OTEL_BLOB_*`` settings the sink uses.

    uv run python -m tools.sweep --days 7
    uv run python -m tools.sweep --since 2026-07-01 --until 2026-07-07 --signal logs
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, date, datetime

import duckdb
import psycopg
from cc_otel_sink.config import load_settings

from ._keypaths import KeyPath, extract_key_paths
from ._registry import Diff, load_registry
from ._reservoir import configure_duckdb
from ._window import SIGNALS, globs, resolve_window


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument(
        "--days", type=int, default=7, help="window = last N days ending today (UTC); default 7"
    )
    p.add_argument(
        "--since", type=date.fromisoformat, help="window start (YYYY-MM-DD); overrides --days"
    )
    p.add_argument(
        "--until", type=date.fromisoformat, help="window end (YYYY-MM-DD); defaults to today (UTC)"
    )
    p.add_argument("--signal", choices=SIGNALS, help="restrict to one blob signal; default both")
    return p.parse_args(argv)


def _window(args: argparse.Namespace) -> list[date]:
    return resolve_window(args.days, args.since, args.until, datetime.now(UTC).date())


def _read_blob_keys(con: duckdb.DuckDBPyConnection, targets: list[str]) -> tuple[set[KeyPath], int]:
    """Extract key paths from every blob matched by ``targets``; also count blobs read."""
    extracted: set[KeyPath] = set()
    blobs = 0
    for target in targets:
        escaped = target.replace("'", "''")
        try:
            rows = con.execute(
                f"SELECT json FROM read_json_objects('{escaped}', format='unstructured')"
            ).fetchall()
        except duckdb.IOException:
            continue  # partition has no blobs for this day/signal
        for (payload_text,) in rows:
            blobs += 1
            extracted |= extract_key_paths(json.loads(payload_text))
    return extracted, blobs


def _format_report(
    days: list[date], signals: tuple[str, ...], blobs: int, keys: int, diff: Diff
) -> str:
    lines = [
        f"Blob sweep: signals={','.join(signals)} "
        f"window={days[0]:%Y-%m-%d}..{days[-1]:%Y-%m-%d} "
        f"({blobs} blobs, {keys} distinct key paths)",
        "",
    ]

    def block(title: str, rows: list[KeyPath]) -> None:
        lines.append(f"{title} ({len(rows)}):")
        if rows:
            lines.extend(f"  {s:<9} {n:<32} {k}" for s, n, k in rows)
        else:
            lines.append("  (none)")
        lines.append("")

    block("Unclassified keys — add promoted/kept/denied rows in a migration", diff.unclassified)
    block("Redaction leaks — DENIED keys present in redacted blobs (investigate #8)", diff.leaks)
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    days = _window(args)
    signals = (args.signal,) if args.signal else SIGNALS
    settings = load_settings()

    con = duckdb.connect()
    try:
        configure_duckdb(con, settings)
        extracted, blobs = _read_blob_keys(con, globs(settings.blob_container, signals, days))
    finally:
        con.close()

    with psycopg.connect(settings.database_url) as conn:
        registry = load_registry(conn)

    diff = registry.diff(extracted)
    print(_format_report(days, signals, blobs, len(extracted), diff))
    return 0


if __name__ == "__main__":
    sys.exit(main())
