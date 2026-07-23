"""The signal fact table: one frozen record per ingested OTLP signal (#230, #149).

``_window`` / ``replay`` / ``gen_data_dictionary`` each used to restate the same
metrics/logs facts (route name, registry name, raw table, time/name columns,
ingest path). They now derive from this single table instead.

**Deliberately excluded** — ``_keypaths`` keeps its ``metrics``/``events``/``resource``
strings: those are OTLP-shape-driven extraction logic, and ``resource`` is a
registry-only pseudo-signal with no route, table, or ingest path. Forcing it into
this table would bend the record.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Signal:
    """One ingested signal's stable facts, keyed off its OTLP route.

    The ``route`` (``metrics`` / ``logs``) is the OTLP path segment and the blob
    partition name; the registry (``meta.column_registry``) instead names logs
    ``events``, so ``registry_name`` and ``raw_table`` diverge from ``route`` there.
    """

    route: str  # OTLP route + blob partition name: "metrics" | "logs"
    registry_name: str  # meta.column_registry signal: "metrics" | "events"
    raw_table: str  # raw.<table>
    time_col: str  # event-time column
    name_col: str  # signal-name column
    ingest_path: str  # sink POST path


SIGNALS: tuple[Signal, ...] = (
    Signal("metrics", "metrics", "metrics", "ts", "metric_name", "/v1/metrics"),
    Signal("logs", "events", "events", "event_time", "event_name", "/v1/logs"),
)
