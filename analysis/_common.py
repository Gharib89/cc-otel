"""Shared reservoir access + payload aggregation for the analysis notebooks (#249).

Thin, notebook-agnostic helpers reused across the lab: read a blob window into
decoded OTLP payloads over DuckDB (reusing the ``tools/`` sweep helpers —
``configure_duckdb`` for the Azure secret, ``partition_glob`` / ``compacted_url``
for the Hive-partition addressing), and the payload aggregations the notebooks share (key-path fill
counts, attribute-value sampling). Analysis *narrative* lives in the notebooks;
these primitives stay here so they can be unit-tested without a live reservoir.
"""

from __future__ import annotations

import json
import os
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any

import duckdb
from cc_otel_sink.attrs import event_name
from dotenv import load_dotenv

from tools._keypaths import METRIC_KINDS, KeyPath, extract_key_paths
from tools._window import compacted_url, partition_glob

if TYPE_CHECKING:
    from collections.abc import Iterator
    from datetime import date

    from duckdb import DuckDBPyConnection

_REPO_ROOT = Path(__file__).resolve().parents[1]


def load_env(env_file: str | os.PathLike[str] | None = None) -> Path | None:
    """Load a repo-root ``.env.<env>`` into ``os.environ``; return the file, or ``None``.

    The notebooks read the reservoir and marts settings from the environment
    (``cc_otel_sink.config.load_settings``), but a marimo kernel has no shell to
    ``set -a; . ./.env.interim; set +a`` into — so the load happens here instead.
    Defaults to ``.env.interim``; ``CC_OTEL_ENV_FILE`` selects another file (e.g.
    ``.env.prod``, or an absolute path). A missing file is not an error: the
    notebook then runs on whatever the environment already carries.

    ``override=True`` on purpose: marimo auto-loads the repo-root ``.env`` into the
    kernel before any cell runs, and that file points at the POC server (no
    ``meta.column_registry``, no marts) — deferring to the inherited value pointed
    the notebooks at the wrong database. The chosen file names the environment, so
    it wins; to target another one, set ``CC_OTEL_ENV_FILE`` rather than exporting
    individual variables.
    """
    name = env_file if env_file is not None else os.environ.get("CC_OTEL_ENV_FILE", ".env.interim")
    path = Path(name)
    if not path.is_absolute():
        path = _REPO_ROOT / path
    if not path.is_file():
        return None
    load_dotenv(path, override=True)
    return path


def _read(con: DuckDBPyConnection, sql: str) -> list[tuple[str]] | None:
    """Run a payload-text query; ``None`` when the target matched no files.

    DuckDB raises the same "no files found" ``IOException`` for three different
    situations — an empty partition, a partition not compacted yet, and a target that
    was never going to exist — so the distinction is the *caller's* to make and this
    returns ``None`` rather than an empty list. Any other ``IOException`` is a real
    read/credential failure and propagates rather than silently yielding a short read.
    """
    try:
        return con.execute(sql).fetchall()
    except duckdb.IOException as err:
        if "no files found" not in str(err).lower():
            raise
        return None


def read_payloads(
    con: DuckDBPyConnection,
    container: str,
    signals: tuple[str, ...],
    days: list[date],
    compacted_container: str | None = None,
) -> list[dict[str, Any]]:
    """Decode every blob in the ``signals`` x ``days`` window into OTLP payload dicts.

    One query per partition. When ``compacted_container`` is set the partition's
    compacted parquet (ADR-0015) is preferred and the raw glob is only read if that
    file is absent — today's partition is never compacted, and a catch-up may be
    pending, so the fallback is the normal path rather than an error case. Unset (the
    default) reads raw exactly as before. Either way an empty partition contributes
    nothing, and the payload column is ``json VARCHAR`` on both paths, so everything
    downstream of this function is identical.
    """
    payloads: list[dict[str, Any]] = []
    for signal in signals:
        for day in days:
            rows = None
            if compacted_container is not None:
                target = compacted_url(compacted_container, signal, day).replace("'", "''")
                rows = _read(con, f"SELECT json FROM read_parquet('{target}')")
            if rows is None:
                target = partition_glob(container, signal, day).replace("'", "''")
                rows = _read(
                    con, f"SELECT json FROM read_json_objects('{target}', format='unstructured')"
                )
            payloads.extend(json.loads(text) for (text,) in rows or [])
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
    for scalar_field in ("stringValue", "intValue", "doubleValue", "boolValue"):
        if scalar_field in anyvalue:
            return str(anyvalue[scalar_field])
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


def _attr_map(attributes: Any) -> dict[str, str]:
    """Flatten an OTLP ``attributes`` list to a ``key -> display string`` mapping."""
    if not isinstance(attributes, list):
        return {}
    return {
        a["key"]: scalar(a.get("value"))
        for a in attributes
        if isinstance(a, dict) and isinstance(a.get("key"), str)
    }


def iter_records(payload: dict[str, Any]) -> Iterator[tuple[str, str, dict[str, str]]]:
    """Yield ``(signal, signal_name, attrs)`` per data point, log record, and resource block.

    The record grain ``extract_key_paths`` deliberately discards: it answers "which
    key paths exist", this answers "how often, and on whose records". Signal naming
    matches the registry's (``metrics``/``events``/``resource``, resource blocks at
    ``'*'``), so profiles join straight onto ``meta.column_registry``.
    """
    for rm in payload.get("resourceMetrics", []) or []:
        resource = _attr_map((rm.get("resource") or {}).get("attributes"))
        yield "resource", "*", resource
        for sm in rm.get("scopeMetrics", []) or []:
            for metric in sm.get("metrics", []) or []:
                name = metric.get("name")
                if not isinstance(name, str):
                    continue
                for kind in METRIC_KINDS:
                    container = metric.get(kind)
                    if not isinstance(container, dict):
                        continue
                    for dp in container.get("dataPoints", []) or []:
                        yield "metrics", name, _attr_map(dp.get("attributes"))

    for rl in payload.get("resourceLogs", []) or []:
        resource = _attr_map((rl.get("resource") or {}).get("attributes"))
        yield "resource", "*", resource
        for sl in rl.get("scopeLogs", []) or []:
            for record in sl.get("logRecords", []) or []:
                attrs = record.get("attributes")
                yield "events", event_name(attrs, record.get("name")) or "∅", _attr_map(attrs)


VALUE_CAP = 500
"""Distinct values tracked per key before :attr:`KeyStats.capped` is set.

Free-text keys (prompts, error messages) would otherwise grow a Counter per distinct
value across a multi-day window; the cap keeps a wide profile pass in memory while
still reporting "cardinality exceeds the cap", which is itself the promotion verdict.
"""

CROSSTAB_CARD = 25
"""Distinct values a per-value seat cross-tab is kept for.

Only categorical keys get one: past this many values the key is an identifier or a
measure, where "which seats carry value V" is noise rather than evidence.
"""


@dataclass
class KeyStats:
    """Record-grain profile of one key path — or of a whole signal-name population."""

    records: int = 0
    sessions: set[str] = field(default_factory=set)
    seats: set[str] = field(default_factory=set)
    values: Counter[str] = field(default_factory=Counter)
    capped: bool = False
    value_seats: dict[str, set[str]] = field(default_factory=dict)
    """Seat reach per value — complete only while ``len(values) <= CROSSTAB_CARD``.

    Answers "is this value one developer or the fleet?", which a value *count* cannot:
    a category carried by 4,000 records from two seats is a different promotion case
    from the same count spread across twenty.
    """

    def observe(self, session: str, seat: str, value: str | None) -> None:
        self.records += 1
        if session:
            self.sessions.add(session)
        if seat:
            self.seats.add(seat)
        if value is None:
            return
        if value in self.values or len(self.values) < VALUE_CAP:
            self.values[value] += 1
        else:
            self.capped = True
        if seat and (value in self.value_seats or len(self.value_seats) < CROSSTAB_CARD):
            self.value_seats.setdefault(value, set()).add(seat)


@dataclass
class Profile:
    """Per-key-path stats plus the per-signal-name population they are a share of.

    ``update`` is additive, so a wide window streams day by day instead of holding
    every payload in memory at once.
    """

    keys: dict[KeyPath, KeyStats] = field(default_factory=dict)
    populations: dict[tuple[str, str], KeyStats] = field(default_factory=dict)

    def update(self, payloads: list[dict[str, Any]]) -> None:
        for payload in payloads:
            for signal, name, attrs in iter_records(payload):
                # Identity rides on the record's own attributes for signal records and
                # on the block itself for resource pseudo-records — one lookup covers both.
                session = attrs.get("session.id", "")
                seat = attrs.get("user.email", "").strip().lower()
                self.populations.setdefault((signal, name), KeyStats()).observe(session, seat, None)
                for key, value in attrs.items():
                    stats = self.keys.setdefault((signal, name, key), KeyStats())
                    stats.observe(session, seat, value)


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
