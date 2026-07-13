"""In-process counter for defense-in-depth redaction strips (#8).

A "gate leak" is non-empty content that reached the sink despite a fleet client
gate that should have suppressed it — a rising count means a gate drifted out of
config. (Distinct from the glossary's *Drift*, which is an unregistered attrs
key.) Exposed on ``/healthz`` for scraping.
"""

from __future__ import annotations

_gate_leaks = 0


def record_gate_leaks(n: int) -> None:
    global _gate_leaks
    _gate_leaks += n


def gate_leak_count() -> int:
    return _gate_leaks


def reset() -> None:
    """Test hook."""
    global _gate_leaks
    _gate_leaks = 0
