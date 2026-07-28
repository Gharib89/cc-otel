"""Unit coverage for analysis._common (no live reservoir)."""

from __future__ import annotations

import os
from collections import Counter
from datetime import date

import duckdb
import pytest

from analysis._common import (
    attr_value_samples,
    fill_counts,
    iter_attrs,
    load_env,
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


def test_load_env_overrides_the_inherited_environment(tmp_path, monkeypatch) -> None:
    env_file = tmp_path / ".env.test"
    env_file.write_text(
        "CC_OTEL_BLOB_ACCOUNT_URL=https://acct.blob.core.windows.net\nDATABASE_URL=from-file\n"
    )
    monkeypatch.delenv("CC_OTEL_BLOB_ACCOUNT_URL", raising=False)
    # marimo auto-loads the repo-root `.env` (POC database) before any cell runs
    monkeypatch.setenv("DATABASE_URL", "poc-from-marimo-dotenv")

    assert load_env(env_file) == env_file
    assert os.environ["CC_OTEL_BLOB_ACCOUNT_URL"] == "https://acct.blob.core.windows.net"
    assert os.environ["DATABASE_URL"] == "from-file"  # the chosen env file wins


def test_load_env_missing_file_is_not_an_error(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("CC_OTEL_ENV_FILE", str(tmp_path / "absent"))
    assert load_env() is None
