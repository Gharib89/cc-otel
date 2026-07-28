"""Extract the value-bearing key paths from a decoded OTLP payload.

The sweep (``tools.sweep``) diffs these against ``meta.column_registry`` to surface
attribute keys that have not yet been classified promoted/kept/denied (#16, #29).

A key path is a ``(signal, signal_name, attr_path)`` triple in the registry's own
vocabulary (see db/migrations/…_seed_column_registry.sql):

* ``signal``      — ``'metrics'`` | ``'events'`` | ``'resource'``
* ``signal_name`` — the metric/event name for datapoint/record attrs; ``'*'`` for
  resource-block attrs (recorded once, uniform across signals)
* ``attr_path``   — the raw OTLP attribute ``key``

Only keys that live in an ``attributes`` list are emitted — structural paths
(``timeUnixNano``, ``dataPoint.value``, ``scope.name``) are read from JSON structure by
the sink parser, never as attributes, so they are deliberately not extracted here.
Those paths are recorded in ``cc_otel_sink.column_spec`` as ``kind="structural"``
rows (the authoritative catalogue); this module does not re-list them.
"""

from __future__ import annotations

from typing import Any

from cc_otel_sink.attrs import event_name as _event_name

KeyPath = tuple[str, str, str]

# OTLP metric data are carried under one of these per-metric containers.
METRIC_KINDS = ("gauge", "sum", "histogram", "exponentialHistogram", "summary")


def _attr_keys(attributes: Any) -> list[str]:
    if not isinstance(attributes, list):
        return []
    return [a["key"] for a in attributes if isinstance(a, dict) and isinstance(a.get("key"), str)]


def _resource_attrs(resource: Any) -> list[str]:
    if not isinstance(resource, dict):
        return []
    return _attr_keys(resource.get("attributes"))


def extract_key_paths(payload: dict[str, Any]) -> set[KeyPath]:
    """Return the distinct ``(signal, signal_name, attr_path)`` triples in ``payload``.

    Accepts an OTLP/JSON metrics *or* logs payload (the two shapes the sink ingests);
    unknown shapes yield an empty set rather than raising.
    """
    out: set[KeyPath] = set()

    for rm in payload.get("resourceMetrics", []) or []:
        for key in _resource_attrs(rm.get("resource")):
            out.add(("resource", "*", key))
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
                        for key in _attr_keys(dp.get("attributes")):
                            out.add(("metrics", name, key))

    for rl in payload.get("resourceLogs", []) or []:
        for key in _resource_attrs(rl.get("resource")):
            out.add(("resource", "*", key))
        for sl in rl.get("scopeLogs", []) or []:
            for record in sl.get("logRecords", []) or []:
                name = _event_name(record.get("attributes"), record.get("name")) or "∅"
                for key in _attr_keys(record.get("attributes")):
                    out.add(("events", name, key))

    return out
