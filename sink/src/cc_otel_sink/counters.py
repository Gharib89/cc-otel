"""In-process counter for defense-in-depth redaction strips (#8).

A rising count means a fleet client gate drifted (raw content reaching the sink
that a gate should have suppressed). Exposed on ``/healthz`` for scraping.
"""

from __future__ import annotations

_drift_strips = 0


def record_drift_strips(n: int) -> None:
    global _drift_strips
    _drift_strips += n


def drift_strip_count() -> int:
    return _drift_strips


def reset() -> None:
    """Test hook."""
    global _drift_strips
    _drift_strips = 0
