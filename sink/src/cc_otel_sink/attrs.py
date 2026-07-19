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


def event_name(attributes: list[dict[str, Any]] | None, fallback: Any = None) -> str | None:
    """Resolve a log record's event name to the unprefixed form the registry uses.

    Claude Code's OTel names events unprefixed (``tool_result``), matching the
    column-registry seed; strip a ``claude_code.`` prefix defensively so both the
    promoted-column routing and the redaction sweep still key correctly if the
    collector ever forwards the fully-qualified name.
    """
    name = get_attr(attributes, "event.name")
    if not isinstance(name, str):
        name = fallback if isinstance(fallback, str) else None
    if isinstance(name, str):
        return name.removeprefix("claude_code.")
    return None
