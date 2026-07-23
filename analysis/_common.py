"""Shared reservoir access + payload aggregation for the analysis notebooks (#249).

Thin, notebook-agnostic helpers reused across the lab: read a blob window into
decoded OTLP payloads over DuckDB (reusing the ``tools/`` sweep helpers —
``configure_duckdb`` for the Azure secret, ``globs`` for the Hive-partition
addressing), and the payload aggregations the notebooks share (key-path fill
counts, attribute-value sampling). Analysis *narrative* lives in the notebooks;
these primitives stay here so they can be unit-tested without a live reservoir.
"""

from __future__ import annotations

import json
from collections import Counter
from typing import TYPE_CHECKING, Any

import duckdb

from tools._keypaths import KeyPath, extract_key_paths
from tools._window import globs

if TYPE_CHECKING:
    from collections.abc import Iterator
    from datetime import date

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


def fill_counts(payloads: list[dict[str, Any]]) -> Counter[KeyPath]:
    """Count, per ``(signal, signal_name, attr_path)``, how many payloads carry it.

    Blob-level presence (a key is counted once per payload regardless of how many
    data points repeat it) — the fill-rate numerator the sweep-style notebooks share.
    """
    counts: Counter[KeyPath] = Counter()
    for payload in payloads:
        counts.update(extract_key_paths(payload))
    return counts


def scalar(anyvalue: Any) -> str:
    """Flatten an OTLP ``AnyValue`` to a display string (first scalar field wins)."""
    if not isinstance(anyvalue, dict):
        return str(anyvalue)
    for field in ("stringValue", "intValue", "doubleValue", "boolValue"):
        if field in anyvalue:
            return str(anyvalue[field])
    return str(anyvalue)


def iter_attrs(obj: Any) -> Iterator[tuple[str, Any]]:
    """Yield every OTLP ``(key, AnyValue)`` attribute pair anywhere in ``obj``.

    Structure-agnostic recursive walk — finds resource, data-point, and log-record
    attributes alike without re-encoding the OTLP shape (that lives in
    ``tools._keypaths``; here only raw ``{"key", "value"}`` pairs matter).
    """
    if isinstance(obj, dict):
        if isinstance(obj.get("key"), str) and "value" in obj:
            yield obj["key"], obj["value"]
        for value in obj.values():
            yield from iter_attrs(value)
    elif isinstance(obj, list):
        for item in obj:
            yield from iter_attrs(item)


def attr_value_samples(payloads: list[dict[str, Any]]) -> dict[str, Counter[str]]:
    """Map each attribute key to a value -> occurrence ``Counter`` across ``payloads``.

    Keyed by the raw attribute key (not the full key path), so a key seen under
    several signals pools its values — enough for cardinality and example values in
    promotion triage; ``len`` is the cardinality and ``most_common`` the examples.
    """
    samples: dict[str, Counter[str]] = {}
    for payload in payloads:
        for key, value in iter_attrs(payload):
            samples.setdefault(key, Counter())[scalar(value)] += 1
    return samples
