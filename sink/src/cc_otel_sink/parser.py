"""OTLP/JSON → raw-table rows.

The promoted-column maps are derived at import from the authoritative spec
(``column_spec``) — no registry-driven dynamic dispatch (#16). Attribute keys are
globally unique to their target column, so the flat ``attr → column`` map is
equivalent to the registry's per-signal grouping.

Anything not mapped here is dropped from Postgres — it survives verbatim in the
blob reservoir (ADR-0005).
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from .attrs import event_name, flatten
from .column_spec import attr_columns, bool_columns, float_columns, int_columns

# attr key → raw column (flat, per signal); derived from the promoted attr rows.
METRIC_ATTR_COLUMNS: dict[str, str] = attr_columns("metrics")
EVENT_ATTR_COLUMNS: dict[str, str] = attr_columns("events")

_INT_COLUMNS = int_columns()
_FLOAT_COLUMNS = float_columns()
_BOOL_COLUMNS = bool_columns()

_TRUE_STRINGS = frozenset({"true", "t", "1", "yes"})


def normalize_email(value: Any) -> str | None:
    """Lowercase + trim the client-asserted identity; empty/missing → None (#6)."""
    if not isinstance(value, str):
        return None
    cleaned = value.strip().lower()
    return cleaned or None


def _ts(nano: Any) -> datetime | None:
    if nano is None:
        return None
    ns = int(nano)
    return datetime.fromtimestamp(ns // 1_000_000_000, tz=UTC).replace(
        microsecond=(ns % 1_000_000_000) // 1000
    )


def _coerce(column: str, value: Any) -> Any:
    if value is None:
        return None
    if column in _INT_COLUMNS:
        return int(value)
    if column in _FLOAT_COLUMNS:
        return float(value)
    if column in _BOOL_COLUMNS:
        if isinstance(value, bool):
            return value
        return str(value).strip().lower() in _TRUE_STRINGS
    return value


def _apply_promoted(
    row: dict[str, Any],
    attrs: dict[str, Any],
    mapping: dict[str, str],
    resource_version: str | None,
) -> None:
    for key, column in mapping.items():
        if key in attrs:
            row[column] = _coerce(column, attrs[key])
    if "user_email" in row:
        row["user_email"] = normalize_email(row["user_email"])
    # Coalesce composite identities.
    account = attrs.get("user.account_uuid") or attrs.get("user.account_id")
    if account is not None:
        row["user_account_id"] = account
    # cc_version = app.version, falling back to resource service.version.
    cc_version = attrs.get("app.version") or resource_version
    if cc_version is not None:
        row["cc_version"] = cc_version


def _value_kind(metric_type: str, temporality: Any) -> str:
    if metric_type == "gauge":
        return "gauge_last"
    if metric_type == "histogram":
        return "hist_sum"
    # sum: temporality may be int (1/2) or the OTLP enum string.
    if temporality in (1, "AGGREGATION_TEMPORALITY_DELTA"):
        return "sum_delta"
    return "sum_cumulative"


def parse_metrics(payload: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for rm in payload.get("resourceMetrics", []) or []:
        resource = rm.get("resource", {})
        res_attrs = flatten(resource.get("attributes"))
        resource_version = res_attrs.get("service.version")
        for sm in rm.get("scopeMetrics", []) or []:
            scope = sm.get("scope", {})
            scope_name = scope.get("name")
            scope_version = scope.get("version")
            for metric in sm.get("metrics", []) or []:
                name = metric.get("name")
                for metric_type in ("gauge", "sum", "histogram"):
                    inst = metric.get(metric_type)
                    if inst is None:
                        continue
                    temporality = inst.get("aggregationTemporality")
                    for dp in inst.get("dataPoints", []) or []:
                        rows.append(
                            _metric_row(
                                name,
                                metric_type,
                                temporality,
                                dp,
                                res_attrs,
                                resource_version,
                                scope_name,
                                scope_version,
                            )
                        )
    return rows


def _metric_row(
    name: str,
    metric_type: str,
    temporality: Any,
    dp: dict[str, Any],
    res_attrs: dict[str, Any],
    resource_version: str | None,
    scope_name: str | None,
    scope_version: str | None,
) -> dict[str, Any]:
    attrs = {**res_attrs, **flatten(dp.get("attributes"))}
    row: dict[str, Any] = {
        "ts": _ts(dp.get("timeUnixNano")),
        "metric_name": name,
        "metric_type": metric_type,
        "value_kind": _value_kind(metric_type, temporality),
        "scope_name": scope_name,
        "scope_version": scope_version,
    }
    if metric_type == "histogram":
        row["count"] = _coerce("count", dp.get("count"))
        row["value"] = _coerce("value", dp.get("sum"))
    else:
        raw_value = dp.get("asDouble")
        if raw_value is None:
            raw_value = dp.get("asInt")
        row["value"] = _coerce("value", raw_value)
    _apply_promoted(row, attrs, METRIC_ATTR_COLUMNS, resource_version)
    return row


def parse_events(payload: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for rl in payload.get("resourceLogs", []) or []:
        resource = rl.get("resource", {})
        res_attrs = flatten(resource.get("attributes"))
        resource_version = res_attrs.get("service.version")
        for sl in rl.get("scopeLogs", []) or []:
            scope = sl.get("scope", {})
            scope_name = scope.get("name")
            scope_version = scope.get("version")
            for rec in sl.get("logRecords", []) or []:
                rows.append(_event_row(rec, res_attrs, resource_version, scope_name, scope_version))
    return rows


def _event_row(
    rec: dict[str, Any],
    res_attrs: dict[str, Any],
    resource_version: str | None,
    scope_name: str | None,
    scope_version: str | None,
) -> dict[str, Any]:
    rec_attrs = rec.get("attributes")
    attrs = {**res_attrs, **flatten(rec_attrs)}
    body = rec.get("body")
    row: dict[str, Any] = {
        "event_time": _ts(rec.get("timeUnixNano")),
        "event_name": event_name(rec_attrs, rec.get("name")),
        "severity": rec.get("severityText"),
        "body": body.get("stringValue") if isinstance(body, dict) else None,
        "severity_number": _coerce("severity_number", rec.get("severityNumber")),
        "log_trace_id": rec.get("traceId"),
        "log_span_id": rec.get("spanId"),
        "dropped_attributes_count": _coerce(
            "dropped_attributes_count", rec.get("droppedAttributesCount")
        ),
        "scope_name": scope_name,
        "scope_version": scope_version,
    }
    _apply_promoted(row, attrs, EVENT_ATTR_COLUMNS, resource_version)
    return row
