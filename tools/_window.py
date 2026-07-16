"""Blob-window addressing shared by sweep / scrub / replay.

The reservoir is Hive-partitioned ``signal=<metrics|logs>/dt=<YYYY-MM-DD>/`` (blob.py).
Note the partition uses the OTLP *route* names ``metrics`` / ``logs`` — not the registry's
``events`` — so window helpers speak ``logs``.
"""

from __future__ import annotations

from datetime import date, timedelta

SIGNALS = ("metrics", "logs")


def date_range(since: date, until: date) -> list[date]:
    if since > until:
        raise ValueError(f"since {since} is after until {until}")
    return [since + timedelta(days=n) for n in range((until - since).days + 1)]


def prefixes(signals: tuple[str, ...], days: list[date]) -> list[str]:
    """Blob-name prefixes for ``ContainerClient.list_blobs`` (scrub / replay)."""
    return [f"signal={s}/dt={d:%Y-%m-%d}/" for s in signals for d in days]


def globs(container: str, signals: tuple[str, ...], days: list[date]) -> list[str]:
    """``azure://`` globs for DuckDB ``read_json_objects`` (sweep)."""
    return [
        f"azure://{container}/signal={s}/dt={d:%Y-%m-%d}/*.json.gz" for s in signals for d in days
    ]
