"""Unit coverage for tools._payload (no live reservoir).

Lifted from ``analysis/tests/test_common.py`` alongside the code (#366); the env-loader
tests stayed behind with ``load_env``.
"""

from __future__ import annotations

from collections import Counter
from datetime import date

import duckdb
import pytest

from tools._payload import (
    VALUE_CAP,
    Profile,
    attr_value_samples,
    fill_counts,
    iter_attrs,
    iter_records,
    read_payloads,
    scalar,
)

DAY = date(2026, 7, 1)


def _metrics_payload(host: str, model: str | None) -> dict:
    """Minimal OTLP metrics payload: one resource attr + optional data-point attr."""
    dp: dict = {"attributes": []}
    if model is not None:
        dp["attributes"].append({"key": "model", "value": {"stringValue": model}})
    return {
        "resourceMetrics": [
            {
                "resource": {"attributes": [{"key": "host", "value": {"stringValue": host}}]},
                "scopeMetrics": [{"metrics": [{"name": "m1", "sum": {"dataPoints": [dp]}}]}],
            }
        ]
    }


class _Result:
    def __init__(self, rows: list[tuple[str]]) -> None:
        self._rows = rows

    def fetchall(self) -> list[tuple[str]]:
        return self._rows


class _FakeCon:
    """Stub connection: each execute() yields the next scripted rows or raises it."""

    def __init__(self, outcomes: list[object]) -> None:
        self._outcomes = list(outcomes)
        self.calls: list[str] = []

    def execute(self, sql: str) -> _Result:
        self.calls.append(sql)
        outcome = self._outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return _Result(outcome)  # type: ignore[arg-type]


def test_decodes_json_rows() -> None:
    con = _FakeCon([[('{"x": 1}',), ('{"y": 2}',)]])
    assert read_payloads(con, "raw", ("metrics",), [DAY]) == [{"x": 1}, {"y": 2}]


def test_concatenates_across_globs() -> None:
    con = _FakeCon([[('{"a": 1}',)], [('{"b": 2}',)]])
    assert read_payloads(con, "raw", ("metrics", "logs"), [DAY]) == [{"a": 1}, {"b": 2}]
    assert len(con.calls) == 2  # one read_json_objects per signal x day glob


def test_skips_empty_partition() -> None:
    con = _FakeCon([duckdb.IOException("No files found that match the pattern"), [('{"a": 1}',)]])
    assert read_payloads(con, "raw", ("metrics", "logs"), [DAY]) == [{"a": 1}]


def test_reraises_real_io_error() -> None:
    con = _FakeCon([duckdb.IOException("403 Forbidden: credential token expired")])
    with pytest.raises(duckdb.IOException):
        read_payloads(con, "raw", ("metrics",), [DAY])


_NO_FILES = "No files found that match the pattern"


def test_prefers_the_compacted_partition_and_never_reads_raw() -> None:
    con = _FakeCon([[('{"a": 1}',)]])
    assert read_payloads(con, "raw", ("metrics",), [DAY], "compacted") == [{"a": 1}]
    assert len(con.calls) == 1  # raw never probed once the parquet answered
    assert "read_parquet" in con.calls[0]
    assert "azure://compacted/signal=metrics/dt=2026-07-01/part-0.parquet" in con.calls[0]


def test_falls_back_to_raw_for_an_uncompacted_partition() -> None:
    # "not compacted yet" (today, or a pending catch-up) reaches DuckDB as the same
    # no-files IOException as an empty partition — so the parquet probe must fall through.
    con = _FakeCon([duckdb.IOException(_NO_FILES), [('{"a": 1}',)]])
    assert read_payloads(con, "raw", ("metrics",), [DAY], "compacted") == [{"a": 1}]
    assert "read_parquet" in con.calls[0]  # parquet probed first
    assert "read_json_objects" in con.calls[1]


def test_empty_partition_contributes_nothing_on_both_paths() -> None:
    con = _FakeCon([duckdb.IOException(_NO_FILES), duckdb.IOException(_NO_FILES)])
    assert read_payloads(con, "raw", ("metrics",), [DAY], "compacted") == []


def test_reraises_a_real_io_error_from_the_compacted_probe() -> None:
    con = _FakeCon([duckdb.IOException("403 Forbidden: credential token expired")])
    with pytest.raises(duckdb.IOException):
        read_payloads(con, "raw", ("metrics",), [DAY], "compacted")


def test_unset_compacted_container_reads_raw_only() -> None:
    con = _FakeCon([[('{"a": 1}',)]])
    assert read_payloads(con, "raw", ("metrics",), [DAY], None) == [{"a": 1}]
    assert len(con.calls) == 1
    assert "read_json_objects" in con.calls[0]


def test_fill_counts_blob_level_presence() -> None:
    # host in both payloads; model only in the first -> counts are per-payload.
    counts = fill_counts([_metrics_payload("h1", "opus"), _metrics_payload("h2", None)])
    assert counts == Counter({("resource", "*", "host"): 2, ("metrics", "m1", "model"): 1})


def test_scalar_flattens_anyvalue() -> None:
    assert scalar({"stringValue": "opus"}) == "opus"
    assert scalar({"intValue": "5"}) == "5"
    assert scalar({"boolValue": True}) == "True"
    assert scalar("raw") == "raw"  # already-flat value passes through
    assert scalar({"stringValue": "a", "intValue": "b"}) == "a"  # first field wins


def test_iter_attrs_walks_all_attribute_pairs() -> None:
    pairs = dict(iter_attrs(_metrics_payload("h1", "opus")))
    assert pairs["host"] == {"stringValue": "h1"}
    assert pairs["model"] == {"stringValue": "opus"}


def test_attr_value_samples_cardinality_and_examples() -> None:
    samples = attr_value_samples([_metrics_payload("h1", "opus"), _metrics_payload("h1", "sonnet")])
    assert samples["model"] == Counter({"opus": 1, "sonnet": 1})  # cardinality 2
    assert samples["host"] == Counter({"h1": 2})  # cardinality 1


def _logs_payload(event: str, attrs: dict[str, str]) -> dict:
    """Minimal OTLP logs payload: one resource attr + one log record."""
    pairs = [{"key": "event.name", "value": {"stringValue": event}}]
    pairs += [{"key": k, "value": {"stringValue": v}} for k, v in attrs.items()]
    return {
        "resourceLogs": [
            {
                "resource": {"attributes": [{"key": "host", "value": {"stringValue": "h1"}}]},
                "scopeLogs": [{"logRecords": [{"attributes": pairs}]}],
            }
        ]
    }


def test_iter_records_yields_resource_block_then_data_points() -> None:
    records = list(iter_records(_metrics_payload("h1", "opus")))
    assert records == [("resource", "*", {"host": "h1"}), ("metrics", "m1", {"model": "opus"})]


def test_iter_records_names_log_records_by_event_name() -> None:
    signal, name, attrs = list(iter_records(_logs_payload("tool_result", {"tool_name": "Bash"})))[1]
    assert (signal, name) == ("events", "tool_result")
    assert attrs["tool_name"] == "Bash"


def test_profile_counts_records_sessions_and_seats() -> None:
    profile = Profile()
    profile.update(
        [
            _logs_payload(
                "tool_result", {"session.id": "s1", "user.email": "A@x.com", "t": "Bash"}
            ),
            _logs_payload(
                "tool_result", {"session.id": "s1", "user.email": "a@x.com", "t": "Read"}
            ),
            _logs_payload(
                "tool_result", {"session.id": "s2", "user.email": "b@x.com", "t": "Bash"}
            ),
        ]
    )

    stats = profile.keys[("events", "tool_result", "t")]
    assert stats.records == 3
    assert stats.sessions == {"s1", "s2"}
    assert stats.seats == {"a@x.com", "b@x.com"}  # normalized, so one seat not two
    assert stats.values == Counter({"Bash": 2, "Read": 1})
    assert stats.value_seats == {"Bash": {"a@x.com", "b@x.com"}, "Read": {"a@x.com"}}
    assert profile.populations[("events", "tool_result")].records == 3


def test_profile_caps_distinct_values_but_keeps_counting() -> None:
    profile = Profile()
    profile.update([_logs_payload("user_prompt", {"p": f"v{n}"}) for n in range(VALUE_CAP + 5)])

    stats = profile.keys[("events", "user_prompt", "p")]
    assert stats.records == VALUE_CAP + 5  # every record still counted
    assert len(stats.values) == VALUE_CAP  # ...but only VALUE_CAP distinct values retained
    assert stats.capped
