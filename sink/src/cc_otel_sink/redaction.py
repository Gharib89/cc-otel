"""Single redaction pass over a decoded OTLP payload (#8).

Runs post-decode, pre-fan-out: the same redacted object feeds both the Postgres
write and the blob-reservoir write, and the idempotency hash is taken over it.

Three strip families:

* **Denylist** — the POC four secret-bearing keys, removed from every attribute
  list wherever they appear.
* **tool_parameters sweep** — a recursive strip of the same secret keys nested
  inside the ``tool_parameters`` attribute on ``tool_result`` / ``tool_decision``
  events (client may pack raw args there).
* **Defense-in-depth** — content keys that fleet client gates already suppress
  (``prompt`` / ``response`` / ``body`` / ``body_ref``); stripping a *non-empty*
  one means a client gate drifted, so those strips are counted and warned on.

Kept verbatim: ``tool_name`` / all ``*_name`` attrs, ``command_name``, enums
(``decision`` / ``source`` / ``category``), ``user.email``, numeric counts. No
key-name pattern matching.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .attrs import event_name as _event_name_of

# POC four — secret-bearing, stripped wherever seen.
DENYLIST = frozenset({"full_command", "bash_command", "file_path", "error"})

# Recursive sweep inside tool_parameters (the "error" key is not a tool arg).
TOOL_PARAM_KEYS = frozenset({"full_command", "bash_command", "file_path"})
TOOL_PARAM_EVENTS = frozenset({"tool_result", "tool_decision"})

# Content keys already suppressed by client gates; a non-empty hit signals drift.
DEFENSE_IN_DEPTH = frozenset({"prompt", "response", "body", "body_ref"})


@dataclass
class RedactionResult:
    payload: dict[str, Any]
    # Count of non-empty defense-in-depth values removed — content that leaked
    # past a client gate (see counters.py).
    gate_leaks: int


def _value_is_nonempty(value: dict[str, Any]) -> bool:
    if not value:
        return False
    sv = value.get("stringValue")
    if sv is not None:
        return sv != ""
    # Any non-string typed value present counts as content.
    return any(
        k in value for k in ("intValue", "doubleValue", "boolValue", "arrayValue", "kvlistValue")
    )


def _strip_denylist(attributes: list[dict[str, Any]]) -> None:
    attributes[:] = [a for a in attributes if a.get("key") not in DENYLIST]


def _sweep_tool_parameters(value: dict[str, Any]) -> None:
    """Recursively remove TOOL_PARAM_KEYS from a nested kvlist/array value."""
    kv = value.get("kvlistValue")
    if isinstance(kv, dict) and isinstance(kv.get("values"), list):
        kv["values"] = [e for e in kv["values"] if e.get("key") not in TOOL_PARAM_KEYS]
        for e in kv["values"]:
            _sweep_tool_parameters(e.get("value", {}))
    arr = value.get("arrayValue")
    if isinstance(arr, dict) and isinstance(arr.get("values"), list):
        for e in arr["values"]:
            _sweep_tool_parameters(e)


def _walk_attribute_lists(node: Any):
    """Yield every ``attributes`` list anywhere in the OTLP tree."""
    if isinstance(node, dict):
        for key, val in node.items():
            if key == "attributes" and isinstance(val, list):
                yield val
            else:
                yield from _walk_attribute_lists(val)
    elif isinstance(node, list):
        for item in node:
            yield from _walk_attribute_lists(item)


def _iter_log_records(payload: dict[str, Any]):
    for rl in payload.get("resourceLogs", []) or []:
        for sl in rl.get("scopeLogs", []) or []:
            yield from sl.get("logRecords", []) or []


def _event_name(record: dict[str, Any]) -> str | None:
    return _event_name_of(record.get("attributes"), record.get("name"))


def redact(payload: dict[str, Any]) -> RedactionResult:
    """Redact ``payload`` in place, returning it plus the drift-strip count."""
    # 1. Denylist strip on every attribute list, wherever it sits.
    for attributes in _walk_attribute_lists(payload):
        _strip_denylist(attributes)

    gate_leaks = 0
    for record in _iter_log_records(payload):
        attributes = record.get("attributes")
        if not isinstance(attributes, list):
            continue

        # 2. Recursive tool_parameters sweep on tool_result / tool_decision.
        if _event_name(record) in TOOL_PARAM_EVENTS:
            for a in attributes:
                if a.get("key") == "tool_parameters":
                    _sweep_tool_parameters(a.get("value", {}))

        # 3. Defense-in-depth strip; count non-empty removals.
        kept: list[dict[str, Any]] = []
        for a in attributes:
            if a.get("key") in DEFENSE_IN_DEPTH:
                if _value_is_nonempty(a.get("value", {})):
                    gate_leaks += 1
                continue
            kept.append(a)
        attributes[:] = kept

    return RedactionResult(payload=payload, gate_leaks=gate_leaks)
