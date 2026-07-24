"""Re-redact a blob window **in place** — the scrub-on-deny job (#8, #29).

When a key is newly classified ``denied``, blobs written before that decision still hold
it. This rewrites each blob in the window through the sink's own ``redact`` and the same
canonical serialization, then overwrites it. It deliberately does **not** touch
``meta.processed_batches``: scrubbing changes the payload bytes, so the batch hash would
change — replaying through the sink (``tools.replay``) is the wrong tool for a deny, this
is. Postgres already dropped the denied key at ingest (or never promoted it), so only the
blob reservoir needs the rewrite.

Destructive (overwrites blobs); dry-run by default. Pass ``--execute`` to write.

    uv run python -m tools.scrub --days 30                 # dry-run: count blobs
    uv run python -m tools.scrub --since 2026-06-01 --until 2026-06-30 --execute
"""

from __future__ import annotations

import argparse
import gzip
import json
import sys
from datetime import UTC, date, datetime
from typing import NamedTuple

from cc_otel_sink.canonical import canonical_bytes
from cc_otel_sink.config import load_settings
from cc_otel_sink.redaction import redact

from ._progress import Progress
from ._reservoir import CurationReservoir
from ._window import prefixes, resolve_window
from .signals import ROUTES


def rescrub(blob_bytes: bytes) -> tuple[bytes, int]:
    """Return re-redacted gzip bytes for one blob, plus the defense-in-depth leak count.

    Idempotent on an already-clean blob: its content is already canonical, so redact is a
    no-op and the decompressed output is byte-identical to the input's.
    """
    result = redact(json.loads(gzip.decompress(blob_bytes)))
    return gzip.compress(canonical_bytes(result.payload)), result.gate_leaks


class Counts(NamedTuple):
    """Blobs seen, blobs rewritten (or would-be, on a dry run), defense-in-depth leaks."""

    scanned: int
    rewritten: int
    leaks: int


def run(
    reservoir: CurationReservoir, signals: tuple[str, ...], days: list[date], execute: bool
) -> Counts:
    """Stream the window one blob at a time, rewriting dirty blobs when ``execute``.

    Accepts the reservoir rather than creating it, so the destructive sequence
    (download -> rescrub -> compare -> overwrite-if-dirty) is unit-testable against a
    fake. The caller owns the reservoir's lifecycle (open/close).
    """
    scanned = rewritten = leaks = 0
    progress = Progress("scrub blobs")
    for prefix in prefixes(signals, days):
        for name in reservoir.list_names(prefix):
            scanned += 1
            progress.tick()
            original = reservoir.download(name)
            scrubbed, blob_leaks = rescrub(original)
            leaks += blob_leaks
            if gzip.decompress(scrubbed) == gzip.decompress(original):
                continue  # already clean — skip the write
            if execute:
                reservoir.overwrite(name, scrubbed)
            rewritten += 1
    progress.done()
    return Counts(scanned, rewritten, leaks)


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument(
        "--days", type=int, default=30, help="window = last N days ending today (UTC); default 30"
    )
    p.add_argument(
        "--since", type=date.fromisoformat, help="window start (YYYY-MM-DD); overrides --days"
    )
    p.add_argument(
        "--until", type=date.fromisoformat, help="window end (YYYY-MM-DD); defaults to today (UTC)"
    )
    p.add_argument("--signal", choices=ROUTES, help="restrict to one blob signal; default both")
    p.add_argument("--execute", action="store_true", help="overwrite blobs (default: dry-run)")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    days = resolve_window(args.days, args.since, args.until, datetime.now(UTC).date())
    signals = (args.signal,) if args.signal else ROUTES

    reservoir = CurationReservoir.from_settings(load_settings())
    try:
        counts = run(reservoir, signals, days, args.execute)
    finally:
        reservoir.close()

    verb = "rewrote" if args.execute else "would rewrite"
    print(
        f"Scrub {days[0]:%Y-%m-%d}..{days[-1]:%Y-%m-%d} signals={','.join(signals)}: "
        f"scanned {counts.scanned} blobs, {verb} {counts.rewritten} "
        f"({counts.leaks} defense-in-depth leaks seen)"
        + ("" if args.execute else " — dry-run, pass --execute to write")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
