import json

import duckdb
import pytest

from tools.sweep import _read_blob_keys


class _Cursor:
    def __init__(self, result, exc):
        self._result = result
        self._exc = exc

    def fetchall(self):
        if self._exc is not None:
            raise self._exc
        return self._result


class _Con:
    """Stand-in DuckDB connection: one queued (result, exc) per target ``execute``."""

    def __init__(self, per_target):
        self._queue = list(per_target)

    def execute(self, _sql):
        return _Cursor(*self._queue.pop(0))


def test_empty_partition_ioexception_is_treated_as_no_blobs():
    # A glob that matches no blobs raises IOException "No files found ..." — a legitimately
    # empty day/signal partition, safe to skip.
    con = _Con([(None, duckdb.IOException("IO Error: No files found that match the pattern x"))])
    assert _read_blob_keys(con, ["azure://raw/signal=logs/dt=2026-07-18/*.json.gz"]) == (set(), 0)


def test_read_or_credential_ioexception_is_not_swallowed():
    # A real read/credential failure must NOT be reported as an empty partition, or the sweep
    # falsely reads "all-clean" over data it never saw.
    con = _Con(
        [(None, duckdb.IOException("IO Error: could not open file ... Failed to get token"))]
    )
    with pytest.raises(duckdb.IOException):
        _read_blob_keys(con, ["azure://raw/signal=logs/dt=2026-07-16/*.json.gz"])


def test_reads_and_counts_blobs():
    payload = json.dumps(
        {
            "resourceLogs": [
                {
                    "scopeLogs": [
                        {
                            "logRecords": [
                                {
                                    "attributes": [
                                        {
                                            "key": "event.name",
                                            "value": {"stringValue": "tool_result"},
                                        }
                                    ]
                                }
                            ]
                        }
                    ]
                }
            ]
        }
    )
    con = _Con([([(payload,)], None)])
    keys, blobs = _read_blob_keys(con, ["azure://raw/signal=logs/dt=2026-07-14/*.json.gz"])
    assert blobs == 1
    assert keys
