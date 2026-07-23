"""Unit coverage for analysis._common.read_payloads (no live reservoir)."""

from __future__ import annotations

from datetime import date

import duckdb
import pytest

from analysis._common import read_payloads

DAY = date(2026, 7, 1)


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
