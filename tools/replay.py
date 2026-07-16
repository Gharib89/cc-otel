"""Rebuild a blob window through the sink — the ingest-reliability replay (#7, #29).

To recover from a sink/DB incident, re-drive a window of redacted blobs back through the
sink so raw → staging → marts rebuild from the reservoir. Because a blob's content is
exactly the canonical redacted bytes the sink hashed, its batch hash is
``sha256(gunzip(blob))``; ``meta.processed_batches`` must be cleared for those hashes
first or the sink's idempotency guard makes the re-POST a silent no-op.

Sequence (``--execute``): delete raw rows in the time window + the window's batch hashes,
then re-POST each blob to the sink (``/v1/metrics`` or ``/v1/logs`` per its partition).
Raw rows are keyed by event time, not blob path, so a window is a *time range* — pick it
generously; ingest-time vs event-time skew at the edges is expected.

Destructive; dry-run by default. Pass ``--execute`` to delete + re-POST.

    uv run python -m tools.replay --since 2026-07-10 --until 2026-07-11        # dry-run
    uv run python -m tools.replay --since 2026-07-10 --until 2026-07-11 --execute --sink-url http://127.0.0.1:8080
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import sys
from datetime import UTC, date, datetime, time, timedelta

import httpx
import psycopg
from cc_otel_sink.config import load_settings

from ._reservoir import CurationReservoir
from ._window import SIGNALS, date_range, prefixes

# raw table, event-time column, POST path — keyed by the blob's signal partition.
_ROUTE = {
    "metrics": ("metrics", "ts", "/v1/metrics"),
    "logs": ("events", "event_time", "/v1/logs"),
}


def blob_hash(blob_bytes: bytes) -> str:
    """The sink's batch hash for a stored blob: sha256 of its decompressed bytes."""
    return hashlib.sha256(gzip.decompress(blob_bytes)).hexdigest()


def endpoint_for(name: str) -> str:
    """Map a blob name (``signal=<sig>/…``) to its sink ingest path."""
    signal = name.split("=", 1)[1].split("/", 1)[0]
    return _ROUTE[signal][2]


def _bounds(since: date, until: date) -> tuple[datetime, datetime]:
    """UTC half-open [start, end) covering the inclusive date window."""
    return (
        datetime.combine(since, time.min, tzinfo=UTC),
        datetime.combine(until + timedelta(days=1), time.min, tzinfo=UTC),
    )


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument(
        "--since", type=date.fromisoformat, required=True, help="window start (YYYY-MM-DD)"
    )
    p.add_argument(
        "--until", type=date.fromisoformat, required=True, help="window end (YYYY-MM-DD, inclusive)"
    )
    p.add_argument("--signal", choices=SIGNALS, help="restrict to one blob signal; default both")
    p.add_argument("--sink-url", default="http://127.0.0.1:8080", help="sink base URL for re-POST")
    p.add_argument("--execute", action="store_true", help="delete + re-POST (default: dry-run)")
    return p.parse_args(argv)


def _count_rows(
    conn: psycopg.Connection, signals: tuple[str, ...], start: datetime, end: datetime
) -> dict[str, int]:
    counts = {}
    with conn.cursor() as cur:
        for sig in signals:
            table, ts_col, _ = _ROUTE[sig]
            cur.execute(
                f'SELECT count(*) FROM raw."{table}" WHERE "{ts_col}" >= %s AND "{ts_col}" < %s',
                (start, end),
            )  # noqa: S608
            counts[table] = cur.fetchone()[0]
    return counts


def _delete_window(
    conn: psycopg.Connection,
    signals: tuple[str, ...],
    start: datetime,
    end: datetime,
    hashes: list[str],
) -> None:
    with conn.cursor() as cur:
        for sig in signals:
            table, ts_col, _ = _ROUTE[sig]
            cur.execute(
                f'DELETE FROM raw."{table}" WHERE "{ts_col}" >= %s AND "{ts_col}" < %s',
                (start, end),
            )  # noqa: S608
        if hashes:  # empty list would send an untyped array param; skip when no blobs
            cur.execute("DELETE FROM meta.processed_batches WHERE batch_hash = ANY(%s)", (hashes,))
    conn.commit()


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    days = date_range(args.since, args.until)
    signals = (args.signal,) if args.signal else SIGNALS
    start, end = _bounds(args.since, args.until)
    settings = load_settings()

    reservoir = CurationReservoir.from_settings(settings)
    try:
        # Names only in memory; hash by downloading each blob then discarding the bytes,
        # and re-download per POST — a large window must not hold every blob in RAM.
        names = [
            name for prefix in prefixes(signals, days) for name in reservoir.list_names(prefix)
        ]
        hashes = [blob_hash(reservoir.download(name)) for name in names]

        with psycopg.connect(settings.database_url) as conn:
            row_counts = _count_rows(conn, signals, start, end)
            print(
                f"Replay {args.since:%Y-%m-%d}..{args.until:%Y-%m-%d} signals={','.join(signals)}: "
                f"{len(names)} blobs / {len(set(hashes))} hashes; "
                f"raw rows in window: {row_counts}"
            )
            if not args.execute:
                print("dry-run — pass --execute to delete window rows + hashes and re-POST")
                return 0

            _delete_window(conn, signals, start, end, hashes)

        with httpx.Client(base_url=args.sink_url, timeout=30) as client:
            for name in names:
                resp = client.post(
                    endpoint_for(name),
                    content=reservoir.download(name),
                    headers={"content-type": "application/json", "content-encoding": "gzip"},
                )
                resp.raise_for_status()
        print(f"re-POSTed {len(names)} blobs to {args.sink_url}")
    finally:
        reservoir.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
