"""Single redaction pass over a decoded OTLP payload (#8).

Runs post-decode, pre-fan-out: the same redacted object feeds both the Postgres
write and the blob-reservoir write, and the idempotency hash is taken over it.

Two strip families:

* **Denylist** — the secret-bearing keys, removed from every attribute list
  wherever they appear. It includes the tool-argument payloads ``tool_parameters``
  and ``tool_input``, denied whole: the fleet emits them as a JSON ``stringValue``,
  so the per-leaf sweep of the nested-kvlist shape this pass used to run stripped
  nothing, while full command lines and absolute paths landed at rest (#369).
* **Defense-in-depth** — content keys that fleet client gates already suppress
  (``prompt`` / ``response`` / ``body`` / ``body_ref``); stripping a *non-empty*
  one means a client gate drifted, so those strips are counted and warned on.

Kept verbatim: ``tool_name`` / all ``*_name`` attrs, ``command_name``, enums
(``decision`` / ``source`` / ``category``), ``user.email``, numeric counts. No
key-name pattern matching.
"""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass
from typing import Any

from .column_spec import defense_in_depth, denylist

# The two strip families, derived from the spec's denied rows (by deny_mode).
# Secret-bearing keys, stripped wherever seen.
DENYLIST = denylist()
# Content keys already suppressed by client gates; a non-empty hit signals drift.
DEFENSE_IN_DEPTH = defense_in_depth()


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
        return bool(sv != "")
    # Any non-string typed value present counts as content.
    return any(
        k in value for k in ("intValue", "doubleValue", "boolValue", "arrayValue", "kvlistValue")
    )


def _strip_denylist(attributes: list[dict[str, Any]]) -> None:
    attributes[:] = [a for a in attributes if a.get("key") not in DENYLIST]


def _walk_attribute_lists(node: Any) -> Iterator[list[dict[str, Any]]]:
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


def _iter_log_records(payload: dict[str, Any]) -> Iterator[dict[str, Any]]:
    for rl in payload.get("resourceLogs", []) or []:
        for sl in rl.get("scopeLogs", []) or []:
            yield from sl.get("logRecords", []) or []


def redact(payload: dict[str, Any]) -> RedactionResult:
    """Redact ``payload`` in place, returning it plus the drift-strip count."""
    # 1. Denylist strip on every attribute list, wherever it sits.
    for attr_list in _walk_attribute_lists(payload):
        _strip_denylist(attr_list)

    gate_leaks = 0
    for record in _iter_log_records(payload):
        attributes = record.get("attributes")
        if not isinstance(attributes, list):
            continue

        # 2. Defense-in-depth strip; count non-empty removals.
        kept: list[dict[str, Any]] = []
        for a in attributes:
            if a.get("key") in DEFENSE_IN_DEPTH:
                if _value_is_nonempty(a.get("value", {})):
                    gate_leaks += 1
                continue
            kept.append(a)
        attributes[:] = kept

    return RedactionResult(payload=payload, gate_leaks=gate_leaks)
