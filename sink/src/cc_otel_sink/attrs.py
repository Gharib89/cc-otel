"""OTLP/JSON attribute decoding.

The collector forwards OTLP over HTTP/JSON. Attribute values are tagged unions
(``{"stringValue": ...}`` / ``{"intValue": "42"}`` / ...); ints arrive as strings
per the OTLP/JSON spec.
"""

from __future__ import annotations

from typing import Any


def attr_value(value: dict[str, Any]) -> Any:
    """Decode a single OTLP AnyValue into a native Python value."""
    if "stringValue" in value:
        return value["stringValue"]
    if "intValue" in value:
        return int(value["intValue"])
    if "doubleValue" in value:
        return float(value["doubleValue"])
    if "boolValue" in value:
        return bool(value["boolValue"])
    if "arrayValue" in value:
        return [attr_value(v) for v in value["arrayValue"].get("values", [])]
    if "kvlistValue" in value:
        return {
            kv["key"]: attr_value(kv.get("value", {}))
            for kv in value["kvlistValue"].get("values", [])
        }
    return None


def flatten(attributes: list[dict[str, Any]] | None) -> dict[str, Any]:
    """Flatten an OTLP ``attributes`` list into a ``{key: value}`` dict."""
    out: dict[str, Any] = {}
    for a in attributes or []:
        key = a.get("key")
        if key is not None:
            out[key] = attr_value(a.get("value", {}))
    return out


def get_attr(attributes: list[dict[str, Any]] | None, key: str) -> Any:
    """Return the decoded value of a single attribute by key, or ``None``."""
    for a in attributes or []:
        if a.get("key") == key:
            return attr_value(a.get("value", {}))
    return None
