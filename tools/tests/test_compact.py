import gzip
import json
from datetime import date

import duckdb
import pytest
from azure.core.exceptions import ResourceNotFoundError

from tools._window import compacted_name, partition_prefix
from tools.compact import (
    MissingCompactedContainer,
    compact_partition,
    plan,
    run,
)

TODAY = date(2026, 7, 28)
SIGNALS = ("logs",)


def _raw(day: date, slug: str) -> str:
    return partition_prefix("logs", day) + slug + ".json.gz"


# --- plan ----------------------------------------------------------------------


def test_plan_skips_todays_still_growing_partition(fake_reservoir):
    # blob.py names every blob from ingest wall-clock UTC, so today's partition is the only
    # one that can still gain files; a file built for it goes stale within the hour.
    raw = fake_reservoir({_raw(TODAY, "a"): b"", _raw(date(2026, 7, 27), "a"): b""})
    assert plan(raw, fake_reservoir(), SIGNALS, TODAY) == [("logs", date(2026, 7, 27))]


def test_plan_skips_partitions_that_already_have_a_counterpart(fake_reservoir):
    done, todo = date(2026, 7, 26), date(2026, 7, 27)
    raw = fake_reservoir({_raw(done, "a"): b"", _raw(todo, "a"): b""})
    compacted = fake_reservoir({compacted_name("logs", done): b""})
    assert plan(raw, compacted, SIGNALS, TODAY) == [("logs", todo)]


def test_plan_rebuild_includes_already_compacted_partitions(fake_reservoir):
    day = date(2026, 7, 26)
    raw = fake_reservoir({_raw(day, "a"): b""})
    compacted = fake_reservoir({compacted_name("logs", day): b""})
    assert plan(raw, compacted, SIGNALS, TODAY, rebuild=True) == [("logs", day)]


def test_plan_bounds_restrict_the_discovered_set(fake_reservoir):
    days = [date(2026, 7, 25), date(2026, 7, 26), date(2026, 7, 27)]
    raw = fake_reservoir({_raw(d, "a"): b"" for d in days})
    assert plan(raw, fake_reservoir(), SIGNALS, TODAY, since=days[1], until=days[1]) == [
        ("logs", days[1])
    ]


def test_plan_covers_every_signal(fake_reservoir):
    day = date(2026, 7, 27)
    raw = fake_reservoir({partition_prefix("metrics", day) + "a.json.gz": b"", _raw(day, "a"): b""})
    assert plan(raw, fake_reservoir(), ("metrics", "logs"), TODAY) == [
        ("metrics", day),
        ("logs", day),
    ]


def test_plan_reports_an_unprovisioned_compacted_container(fake_reservoir):
    # ADR-0015 declares the container in Bicep and never lets the tool create it, so every
    # environment hits this once — an opaque ContainerNotFound traceback is not an answer.
    class _Absent:
        container_name = "compacted"

        def list_names(self, prefix):
            raise ResourceNotFoundError("The specified container does not exist.")

    with pytest.raises(MissingCompactedContainer, match="deploy iac/"):
        plan(fake_reservoir({_raw(date(2026, 7, 27), "a"): b""}), _Absent(), SIGNALS, TODAY)


# --- build ---------------------------------------------------------------------


@pytest.fixture
def local_partition(tmp_path):
    """Two gzipped OTLP blobs on disk + the glob addressing them (stands in for azure://)."""
    for n, payload in enumerate([{"a": 1}, {"b": 2}]):
        (tmp_path / f"batch-{n}.json.gz").write_bytes(gzip.compress(json.dumps(payload).encode()))
    return str(tmp_path / "*.json.gz").replace("\\", "/")


def test_compact_partition_writes_one_payload_text_row_per_blob(local_partition, tmp_path):
    con = duckdb.connect()
    target = tmp_path / "part-0.parquet"
    compact_partition(con, local_partition, target)

    rows = con.execute(
        f"SELECT json FROM read_parquet('{str(target).replace(chr(92), '/')}')"
    ).fetchall()
    # One `json VARCHAR` column holding the payload text — no OTLP schema is committed to,
    # so json.loads downstream of read_payloads is byte-identical to the raw path (ADR-0015).
    assert sorted(text for (text,) in rows) == ['{"a": 1}', '{"b": 2}']


def test_run_uploads_one_parquet_per_partition(fake_reservoir, local_partition, monkeypatch):
    from tools import compact

    monkeypatch.setattr(compact, "partition_glob", lambda *_args: local_partition)
    out = fake_reservoir()
    day = date(2026, 7, 27)

    counts = run(duckdb.connect(), out, "raw", [("logs", day), ("metrics", day)])

    assert out.overwrites == [compacted_name("logs", day), compacted_name("metrics", day)]
    assert counts.partitions == 2
    assert counts.bytes_written == sum(len(b) for b in out.blobs.values())
