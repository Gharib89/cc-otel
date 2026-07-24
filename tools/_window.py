"""Blob-window addressing shared by sweep / scrub / replay.

The reservoir is Hive-partitioned ``signal=<metrics|logs>/dt=<YYYY-MM-DD>/`` (blob.py).
Note the partition uses the OTLP *route* names ``metrics`` / ``logs`` — not the registry's
``events`` — so window helpers speak ``logs``.
"""

from __future__ import annotations

from datetime import date, timedelta


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


def globs(container: str, signals: tuple[str, ...], days: list[date]) -> list[str]:
    """``azure://`` globs for DuckDB ``read_json_objects`` (sweep)."""
    return [f"azure://{container}/{partition_prefix(s, d)}*.json.gz" for s in signals for d in days]
