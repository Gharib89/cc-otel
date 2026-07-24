import gzip
import hashlib
from datetime import UTC, date, datetime

import pytest

from tools._window import partition_prefix
from tools.replay import _bounds, apply, blob_hash, endpoint_for, plan


def test_blob_hash_is_sha256_of_decompressed_bytes():
    raw = b'{"resourceLogs":[]}'
    assert blob_hash(gzip.compress(raw)) == hashlib.sha256(raw).hexdigest()


@pytest.mark.parametrize(
    ("name", "path"),
    [
        ("signal=metrics/dt=2026-07-16/120000-abc.json.gz", "/v1/metrics"),
        ("signal=logs/dt=2026-07-16/120000-abc.json.gz", "/v1/logs"),
    ],
)
def test_endpoint_for_maps_partition_to_route(name, path):
    assert endpoint_for(name) == path


def test_bounds_is_half_open_utc_over_inclusive_dates():
    start, end = _bounds(date(2026, 7, 10), date(2026, 7, 11))
    assert start == datetime(2026, 7, 10, tzinfo=UTC)
    assert end == datetime(2026, 7, 12, tzinfo=UTC)


# --- plan() / apply() over fakes ------------------------------------------------

_DAY = date(2026, 7, 20)
_SIGNALS = ("logs",)


def _name(slug: str) -> str:
    return partition_prefix("logs", _DAY) + slug + ".json.gz"


class _FakeCursor:
    """A cursor that returns queued counts (one per SELECT) and records every SQL."""

    def __init__(self, counts: list[int]) -> None:
        self._counts = list(counts)
        self.executed: list[tuple[str, object]] = []

    def __enter__(self) -> "_FakeCursor":
        return self

    def __exit__(self, *exc: object) -> bool:
        return False

    def execute(self, sql: str, params: object = None) -> None:
        self.executed.append((sql, params))

    def fetchone(self) -> tuple[int]:
        return (self._counts.pop(0),)


class _FakeConn:
    """Records SQL through a single shared cursor; ``commit`` is a no-op flag."""

    def __init__(self, counts: list[int]) -> None:
        self.cur = _FakeCursor(counts)
        self.committed = False

    def cursor(self) -> _FakeCursor:
        return self.cur

    def commit(self) -> None:
        self.committed = True


class _RecordingClient:
    """Captures re-POST calls so a test can assert order vs. the delete."""

    def __init__(self, log: list[str]) -> None:
        self._log = log

    def post(self, path: str, *, content: bytes, headers: dict) -> "_RecordingClient":
        self._log.append(f"POST {path}")
        return self

    def raise_for_status(self) -> None:
        return None


def test_plan_returns_names_hashes_bounds_and_counts(fake_reservoir):
    raw_a, raw_b = b'{"resourceLogs":["a"]}', b'{"resourceLogs":["b"]}'
    res = fake_reservoir({_name("a"): gzip.compress(raw_a), _name("b"): gzip.compress(raw_b)})
    conn = _FakeConn(counts=[7])  # one SELECT for the single "logs" signal

    result = plan(conn, res, _SIGNALS, [_DAY])

    assert result.names == [_name("a"), _name("b")]
    assert result.hashes == [
        hashlib.sha256(raw_a).hexdigest(),
        hashlib.sha256(raw_b).hexdigest(),
    ]
    assert result.start == datetime(2026, 7, 20, tzinfo=UTC)
    assert result.end == datetime(2026, 7, 21, tzinfo=UTC)
    assert result.row_counts == {"events": 7}  # raw.events is the "logs" raw table


def test_plan_does_not_mutate_the_reservoir(fake_reservoir):
    res = fake_reservoir({_name("a"): gzip.compress(b'{"resourceLogs":[]}')})
    plan(_FakeConn(counts=[0]), res, _SIGNALS, [_DAY])
    assert res.overwrites == []  # plan is read-only


def test_apply_clears_ledger_before_reposting(fake_reservoir):
    """The load-bearing invariant: the ledger DELETE must precede every re-POST,
    else the sink's idempotency guard no-ops the replay (module docstring)."""
    res = fake_reservoir({_name("a"): gzip.compress(b'{"resourceLogs":[]}')})
    order: list[str] = []

    class _OrderingConn(_FakeConn):
        def commit(self) -> None:  # delete_window commits after the DELETEs
            order.append("DELETE")
            super().commit()

    conn = _OrderingConn(counts=[1])
    the_plan = plan(conn, res, _SIGNALS, [_DAY])
    apply(conn, res, _RecordingClient(order), the_plan)

    assert order == ["DELETE", "POST /v1/logs"]  # delete strictly before the re-POST
