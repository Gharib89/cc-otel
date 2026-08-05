"""Blob-window addressing shared by sweep / scrub / replay / compact / reservoir_copy and
``analysis``.

The reservoir is Hive-partitioned ``signal=<metrics|logs>/dt=<YYYY-MM-DD>/`` (blob.py). The
compacted reservoir (ADR-0015) reuses that prefix with a fixed ``part-0.parquet`` leaf, so both
addresses are built here and cannot drift apart.
Note the partition uses the OTLP *route* names ``metrics`` / ``logs`` — not the registry's
``events`` — so window helpers speak ``logs``.
"""

from __future__ import annotations

import sys
from datetime import date, timedelta


def partition_days(prefixes: list[str]) -> list[date]:
    """Dates of the ``dt=<YYYY-MM-DD>/`` child prefixes in ``prefixes``, oldest first.

    Ascending so a catch-up run works through the backlog in ingest order. A child that is
    not a ``dt=`` partition — or carries a ``dt=`` value that is not an ISO date — is
    skipped rather than raising: one stray prefix must not abort discovery of the other 27
    partitions. What skipping costs is the caller's own: ``compact`` loses that partition's
    speedup (the read path falls back to raw), while ``reservoir_copy`` would not copy it at
    all. An unparseable ``dt=`` is anomalous either way — only ``blob.py`` writes here, always
    from a formatted UTC date — so it is named on stderr rather than swallowed.
    """
    days = []
    for name in prefixes:
        leaf = name.rstrip("/").rsplit("/", 1)[-1]
        if not leaf.startswith("dt="):
            continue
        try:
            days.append(date.fromisoformat(leaf.removeprefix("dt=")))
        except ValueError:
            print(f"skipping unparseable partition prefix {name!r}", file=sys.stderr)
    return sorted(days)


def date_range(since: date, until: date) -> list[date]:
    if since > until:
        raise ValueError(f"since {since} is after until {until}")
    return [since + timedelta(days=n) for n in range((until - since).days + 1)]


def resolve_window(days: int, since: date | None, until: date | None, today: date) -> list[date]:
    """Resolve the ``--days`` / ``--since`` / ``--until`` triad (sweep, scrub) to dates.

    ``until`` defaults to ``today``; ``since`` defaults to ``days`` back inclusive.
    """
    until = until or today
    since = since or (until - timedelta(days=days - 1))
    return date_range(since, until)


def partition_prefix(signal: str, day: date) -> str:
    """Hive partition prefix ``signal=<sig>/dt=<YYYY-MM-DD>/`` (blob.py layout)."""
    return f"signal={signal}/dt={day:%Y-%m-%d}/"


def prefixes(signals: tuple[str, ...], days: list[date]) -> list[str]:
    """Blob-name prefixes for ``ContainerClient.list_blobs`` (scrub / replay)."""
    return [partition_prefix(s, d) for s in signals for d in days]


def partition_glob(container: str, signal: str, day: date) -> str:
    """``azure://`` glob over one raw partition's gzipped-JSON blobs."""
    return f"azure://{container}/{partition_prefix(signal, day)}*.json.gz"


def globs(container: str, signals: tuple[str, ...], days: list[date]) -> list[str]:
    """``azure://`` globs for DuckDB ``read_json_objects`` (sweep)."""
    return [partition_glob(container, s, d) for s in signals for d in days]


def compacted_name(signal: str, day: date) -> str:
    """Blob name of one partition's compacted parquet — what ``tools.compact`` writes.

    Deliberately the raw layout's own Hive prefix plus a fixed leaf (ADR-0015): one file per
    partition, so a compacted address differs from a raw one only in the leaf, the two globs
    stay symmetric, and the route-name mapping keeps living in ``partition_prefix``.
    """
    return f"{partition_prefix(signal, day)}part-0.parquet"


def compacted_url(container: str, signal: str, day: date) -> str:
    """``azure://`` URL of one partition's compacted parquet — the analysis read path."""
    return f"azure://{container}/{compacted_name(signal, day)}"
