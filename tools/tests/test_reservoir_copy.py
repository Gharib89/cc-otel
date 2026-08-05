from datetime import UTC, date, datetime

import pytest

from tools import reservoir_copy
from tools.reservoir_copy import FLOOR, copy, main, newest_write, plan, verify

SIGNALS = ("metrics", "logs")
INTERIM = "https://ccotelinterim.blob.core.windows.net"
PROD = "https://ccotelprod.blob.core.windows.net"

# --- ingest wall-clock, read off the blob name ------------------------------------


def _blob(signal: str, day: str, leaf: str) -> str:
    return f"signal={signal}/dt={day}/{leaf}.json.gz"


def test_newest_write_reads_the_ingest_clock_off_the_name():
    names = [_blob("logs", "2026-08-03", "091500-abc"), _blob("logs", "2026-08-03", "143005-def")]
    assert newest_write(names) == datetime(2026, 8, 3, 14, 30, 5, tzinfo=UTC)


def test_newest_write_is_none_for_no_blobs():
    assert newest_write([]) is None


def test_newest_write_skips_a_name_it_cannot_parse(capsys):
    # A stray name must not hide the newest real blob — the gate it feeds would then read
    # quiet on unparseable input, which is the opposite of conservative.
    names = [_blob("logs", "2026-08-03", "091500-abc"), "signal=logs/dt=2026-08-03/stray.json.gz"]
    assert newest_write(names) == datetime(2026, 8, 3, 9, 15, tzinfo=UTC)
    assert "stray" in capsys.readouterr().err


def test_newest_write_ignores_a_partition_that_is_not_a_date():
    assert newest_write(["signal=logs/dt=not-a-date/091500-abc.json.gz"]) is None


def test_floor_is_the_cutover_policy_date():
    assert FLOOR == date(2026, 7, 17)


# --- plan --------------------------------------------------------------------------


def test_plan_skips_partitions_below_the_floor(fake_reservoir):
    # Pre-floor blobs die with the interim RG (ADR-0020) — copying them would translate
    # history production's Postgres window has no rows for.
    below, above = _blob("logs", "2026-07-16", "091500-a"), _blob("logs", "2026-07-17", "091500-b")
    partitions = plan(fake_reservoir({below: b"x", above: b"y"}), fake_reservoir(), ("logs",))

    assert [(p.signal, p.day, p.missing) for p in partitions] == [
        ("logs", date(2026, 7, 17), (above,))
    ]


def test_plan_missing_is_what_production_lacks(fake_reservoir):
    shared = _blob("logs", "2026-07-20", "090000-a")
    only_source = _blob("logs", "2026-07-20", "100000-b")
    source = fake_reservoir({shared: b"x", only_source: b"y"})
    target = fake_reservoir({shared: b"x"})

    (partition,) = plan(source, target, ("logs",))

    assert partition.missing == (only_source,)
    assert (partition.source_total, partition.target_total) == (2, 1)


def test_plan_ignores_productions_own_blobs_in_the_same_partition(fake_reservoir):
    # The two sinks write into the same partition after the repoint (ADR-0021) and uuid4 names
    # cannot collide, so a production-only blob is live prod traffic — never a copy target.
    shared = _blob("logs", "2026-07-20", "090000-a")
    source = fake_reservoir({shared: b"x"})
    target = fake_reservoir({shared: b"x", _blob("logs", "2026-07-20", "110000-prod"): b"z"})

    (partition,) = plan(source, target, ("logs",))

    assert partition.missing == ()
    assert (partition.source_total, partition.target_total) == (1, 2)


def test_plan_covers_every_signal_oldest_day_first(fake_reservoir):
    names = [
        _blob("metrics", "2026-07-18", "090000-a"),
        _blob("metrics", "2026-07-17", "090000-b"),
        _blob("logs", "2026-07-19", "090000-c"),
    ]
    partitions = plan(fake_reservoir(dict.fromkeys(names, b"x")), fake_reservoir(), SIGNALS)

    assert [(p.signal, p.day) for p in partitions] == [
        ("metrics", date(2026, 7, 17)),
        ("metrics", date(2026, 7, 18)),
        ("logs", date(2026, 7, 19)),
    ]


# --- copy --------------------------------------------------------------------------


def test_copy_writes_the_missing_blobs_byte_identically(fake_reservoir):
    # Same paths on both ends (ADR-0020) — an identity copy, so replay and curation over the
    # pre-cutover weeks address production exactly as they addressed interim.
    name = _blob("logs", "2026-07-20", "090000-a")
    source, target = fake_reservoir({name: b"payload"}), fake_reservoir()

    counts = copy(source, target, plan(source, target, ("logs",)))

    assert target.blobs == {name: b"payload"}
    assert counts == (1, len(b"payload"))


def test_copy_leaves_productions_own_blobs_untouched(fake_reservoir):
    live = _blob("logs", "2026-07-20", "110000-prod")
    source = fake_reservoir({_blob("logs", "2026-07-20", "090000-a"): b"x"})
    target = fake_reservoir({live: b"live"})

    copy(source, target, plan(source, target, ("logs",)))

    assert target.blobs[live] == b"live"
    assert target.overwrites == [_blob("logs", "2026-07-20", "090000-a")]


def test_copy_is_idempotent_a_second_run_has_nothing_to_move(fake_reservoir):
    source = fake_reservoir({_blob("logs", "2026-07-20", "090000-a"): b"x"})
    target = fake_reservoir()
    copy(source, target, plan(source, target, ("logs",)))

    again = plan(source, target, ("logs",))

    assert [p.missing for p in again] == [()]
    assert copy(source, target, again) == (0, 0)


# --- verify ------------------------------------------------------------------------


def test_verify_is_silent_when_production_holds_every_source_blob(fake_reservoir):
    source = fake_reservoir({_blob("logs", "2026-07-20", "090000-a"): b"x"})
    target = fake_reservoir()
    partitions = plan(source, target, ("logs",))
    copy(source, target, partitions)

    assert verify(source, target, partitions) == []


def test_verify_names_a_partition_production_is_short(fake_reservoir):
    # Re-read from both containers, not from the run's own bookkeeping: a write the SDK
    # accepted but the container never kept must fail the run, not pass on our own count.
    absent = _blob("logs", "2026-07-20", "090000-a")
    source = fake_reservoir({absent: b"x"})
    target = fake_reservoir()
    partitions = plan(source, target, ("logs",))

    (failure,) = verify(source, target, partitions)

    assert "logs 2026-07-20" in failure and absent in failure


# --- CLI: the two refusals, the dry run, and the verified copy ----------------------


@pytest.fixture
def ends(monkeypatch, fake_reservoir):
    """Wire ``main``'s two container ends to fakes, keyed by account URL."""

    def _ends(source_blobs=None, target_blobs=None):
        built = {INTERIM: fake_reservoir(source_blobs), PROD: fake_reservoir(target_blobs)}
        monkeypatch.setattr(reservoir_copy, "open_end", lambda url, _container: built[url])
        return built[INTERIM], built[PROD]

    return _ends


def _now_named_blob() -> str:
    """A source blob name stamped with the current UTC clock — by construction not write-quiet."""
    now = datetime.now(UTC)
    return _blob("logs", f"{now:%Y-%m-%d}", f"{now:%H%M%S}-fresh")


def test_main_needs_both_account_urls(monkeypatch, capsys):
    monkeypatch.delenv("INTERIM_BLOB_ACCOUNT_URL", raising=False)
    monkeypatch.delenv("PROD_BLOB_ACCOUNT_URL", raising=False)

    assert main([]) == 2
    assert "INTERIM_BLOB_ACCOUNT_URL" in capsys.readouterr().err


def test_main_refuses_the_same_account_and_container(ends, capsys):
    # The two URLs differ by one word; a pair resolving to one container would "copy" a
    # container onto itself and verify vacuously.
    assert main(["--source-url", INTERIM, "--target-url", INTERIM]) == 1
    assert "same container" in capsys.readouterr().err


def test_main_dry_run_writes_nothing_and_names_what_is_missing(ends, capsys):
    source, target = ends({_blob("logs", "2026-07-20", "090000-a"): b"x"})

    assert main(["--source-url", INTERIM, "--target-url", PROD]) == 0

    assert target.overwrites == []
    out = capsys.readouterr().out
    assert "2026-07-20  1 missing of 1 interim blob(s)" in out
    assert "pass --execute" in out


def test_main_execute_copies_then_verifies(ends, capsys):
    name = _blob("logs", "2026-07-20", "090000-a")
    source, target = ends({name: b"payload"})

    assert main(["--source-url", INTERIM, "--target-url", PROD, "--execute"]) == 0

    assert target.blobs == {name: b"payload"}
    out = capsys.readouterr().out
    assert "copied 1 blob(s)" in out
    assert "tools.compact" in out  # the derived counterpart is now stale (ADR-0015)


def test_main_execute_refuses_while_interim_is_still_being_written(ends, capsys):
    # ADR-0021's window: until interim has been write-quiet for 24h its right edge is still
    # moving, so a partition listing cannot settle and the verification would pass on a
    # partial window.
    source, target = ends({_now_named_blob(): b"x"})

    assert main(["--source-url", INTERIM, "--target-url", PROD, "--execute"]) == 1

    assert target.overwrites == []
    assert "write-quiet" in capsys.readouterr().err


def test_main_execute_fails_the_run_when_verification_is_short(ends, capsys, monkeypatch):
    name = _blob("logs", "2026-07-20", "090000-a")
    source, target = ends({name: b"x"})
    monkeypatch.setattr(target, "overwrite", lambda *_args: None)  # the container drops the write

    assert main(["--source-url", INTERIM, "--target-url", PROD, "--execute"]) == 1
    assert "Verification FAILED" in capsys.readouterr().err


def test_main_reports_a_window_production_already_holds(ends, capsys):
    name = _blob("logs", "2026-07-20", "090000-a")
    ends({name: b"x"}, {name: b"x"})

    assert main(["--source-url", INTERIM, "--target-url", PROD]) == 0
    assert "holds every" in capsys.readouterr().out
