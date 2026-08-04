"""End-to-end proof for the interim -> prod cutover copy, driven as a CLI (#245, ADR-0020).

Two throwaway Postgres stand in for the two environments: the session-wide ``conn`` / ``pg_url``
from ``conftest`` is **interim** (the source), and this module spins a second container as
**production** (the target). The transport is the risky half here — a per-seat window computed
on one server and applied on another — so it is exercised for real rather than left to a manual
gate the way ``scripts/backfill/`` had to.
"""

from __future__ import annotations

from collections.abc import Iterator

import psycopg
import pytest
from _helpers import ins_event, ins_metric
from conftest import _apply_migrations  # the source's own fixture applies it the same way

from tools.cutover_copy import main

# ADR-0020's boundary, and instants either side of it.
BELOW_FLOOR = "2026-07-16T23:00:00Z"
EARLY = "2026-07-18T10:00:00Z"
LATE = "2026-07-22T10:00:00Z"

# A seat's flip: production's first row. EARLY is below it, LATE above.
FLIP = "2026-07-20T00:00:00Z"

SEAT = "dev.one@itworx.com"
OTHER = "dev.two@itworx.com"


@pytest.fixture(scope="session")
def target_url() -> Iterator[str]:
    from testcontainers.postgres import PostgresContainer

    with PostgresContainer("postgres:16", driver="psycopg") as pg:
        url = pg.get_connection_url(driver=None).replace("localhost", "127.0.0.1")
        with psycopg.connect(url) as conn:
            _apply_migrations(conn)
        yield url


@pytest.fixture
def target(target_url: str) -> Iterator[psycopg.Connection]:
    """Production, truncated per test — mirrors conftest's ``conn`` on the source side."""
    with psycopg.connect(target_url) as c:
        c.autocommit = True
        c.execute(
            "TRUNCATE raw.metrics, raw.events, marts.mart_refresh_log, marts.dq_finding,"
            " ref.roster_drop, ref.identity_alias, staging.stg_identity_alias CASCADE"
        )
        yield c


def metric(
    conn: psycopg.Connection, ts: str, email: str | None = SEAT, session_id: str | None = None
) -> None:
    ins_metric(
        conn,
        ts=ts,
        metric_name="claude_code.session.count",
        metric_type="sum",
        value=1,
        value_kind="sum_delta",
        user_email=email,
        session_id=session_id,
    )


def event(conn: psycopg.Connection, event_time: str, email: str | None = SEAT) -> None:
    ins_event(conn, event_time=event_time, event_name="api_request", user_email=email)


def run(pg_url: str, target_url: str, *extra: str) -> int:
    return main(["--source-url", pg_url, "--target-url", target_url, *extra])


def copy(pg_url: str, target_url: str, *extra: str) -> None:
    assert run(pg_url, target_url, "--execute", *extra) == 0


def quiet_interim(conn: psycopg.Connection, hours: float = 25) -> None:
    """Seed ``meta.processed_batches`` so interim reads as write-quiet for ``--sweep`` (ADR-0021).

    The ``conn`` fixture does not truncate this table (other tests may have left rows), so every
    sweep test resets it and seeds its own row.
    """
    conn.execute("TRUNCATE meta.processed_batches")
    conn.execute(
        "INSERT INTO meta.processed_batches (batch_hash, processed_at)"
        " VALUES ('t1', now() - (%s * interval '1 hour'))",
        (hours,),
    )


def emails(conn: psycopg.Connection, table: str, time_column: str) -> list[tuple[str, str]]:
    """Every row's (user_email, time) — the copy's observable effect, in order."""
    stamp = f"to_char({time_column} AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SSZ')"
    rows = conn.execute(f"SELECT user_email, {stamp} FROM {table} ORDER BY 2, 1").fetchall()
    return [(row[0], row[1]) for row in rows]


def test_copies_only_the_rows_below_the_seats_flip_watermark(
    conn: psycopg.Connection, pg_url: str, target: psycopg.Connection, target_url: str
) -> None:
    for ts in (BELOW_FLOOR, EARLY, LATE):
        metric(conn, ts)
    metric(target, FLIP)

    copy(pg_url, target_url)

    # BELOW_FLOOR is outside ADR-0020's window; LATE sits above the watermark, so it stays in
    # interim. Production keeps its own FLIP row untouched.
    assert emails(target, "raw.metrics", "ts") == [(SEAT, EARLY), (SEAT, FLIP)]
    assert emails(conn, "raw.metrics", "ts") == [
        (SEAT, BELOW_FLOOR),
        (SEAT, EARLY),
        (SEAT, LATE),
    ]


def test_dry_run_names_both_environments_and_writes_nothing(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    metric(conn, EARLY)
    metric(target, FLIP)

    assert run(pg_url, target_url) == 0

    out = capsys.readouterr().out.splitlines()
    # The port is part of both labels: the two containers share a host and a database name, so
    # without it the operator's first check would read as one database twice over.
    assert out[0].startswith("Source (interim):    host=127.0.0.1 port=")
    assert out[1].startswith("Target (production): host=127.0.0.1 port=")
    assert out[0] != out[1]
    assert "raw.metrics: 1 seat(s) flipped, 1 row(s) to copy" in out
    assert out[-1].startswith("Dry-run")
    assert emails(target, "raw.metrics", "ts") == [(SEAT, FLIP)]


def test_each_table_carries_its_own_watermarks(
    conn: psycopg.Connection, pg_url: str, target: psycopg.Connection, target_url: str
) -> None:
    # The seat's machine has emitted a metric to production but no event yet, so it is flipped for
    # raw.metrics and unflipped for raw.events -- the two tables cannot share one watermark set.
    metric(conn, EARLY)
    event(conn, EARLY)
    metric(target, FLIP)

    copy(pg_url, target_url)

    assert emails(target, "raw.metrics", "ts") == [(SEAT, EARLY), (SEAT, FLIP)]
    assert emails(target, "raw.events", "event_time") == []


def test_a_re_run_copies_nothing_further(
    conn: psycopg.Connection, pg_url: str, target: psycopg.Connection, target_url: str
) -> None:
    # Idempotence with no delete step: the first copy drops production's minimum to EARLY, so the
    # second run's window is empty. Duplicates are unreachable, which matters because raw.* has no
    # primary key (ADR-0017).
    metric(conn, EARLY)
    metric(target, FLIP)

    copy(pg_url, target_url)
    copy(pg_url, target_url)

    assert emails(target, "raw.metrics", "ts") == [(SEAT, EARLY), (SEAT, FLIP)]


def test_reports_what_stays_in_interim_and_verifies_the_seats_it_copied(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    metric(conn, EARLY)  # below SEAT's watermark -> copied
    metric(conn, LATE)  # above it -> held
    metric(conn, EARLY, email=OTHER)  # OTHER has not flipped -> held
    metric(conn, EARLY, email=None)  # no seat identity -> held
    metric(target, FLIP)

    copy(pg_url, target_url)

    out = capsys.readouterr().out
    assert "raw.metrics: copied 1 row(s) for 1 seat(s)" in out
    assert (
        "raw.metrics held in interim: 1 row(s) for 1 unflipped seat(s),"
        " 1 row(s) at or above a watermark, 1 row(s) with no user_email" in out
    )
    assert "Verified raw.metrics: per-seat counts match for 1 seat(s)" in out
    assert emails(target, "raw.metrics", "ts") == [(SEAT, EARLY), (SEAT, FLIP)]


def test_flags_a_session_that_emitted_to_both_environments_at_once(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # ADR-0020 assumes the row sets are disjoint (one baked endpoint per machine) and hands
    # detecting the exception to this step. A session straddling the flip is *not* it — those have
    # interim rows below the watermark and production rows above, and merge on session_id. A
    # dual-send is the same session above the watermark on both sides.
    straddling = "aaaaaaaa-0000-0000-0000-000000000001"
    dual_sent = "bbbbbbbb-0000-0000-0000-000000000002"
    metric(conn, EARLY, session_id=straddling)
    metric(target, FLIP, session_id=straddling)
    metric(conn, LATE, session_id=dual_sent)
    metric(target, LATE, session_id=dual_sent)

    copy(pg_url, target_url)

    out = capsys.readouterr().out
    assert f"raw.metrics: 1 session(s) emitted to both environments: {dual_sent}" in out


def test_a_straddling_session_still_writing_to_interim_is_not_a_dual_send(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # The commonest shape after a flip: the machine's *new* process emits to production while an
    # old one, started before the env var changed, keeps writing to interim under its own session.
    # Its interim rows sit either side of the watermark, and the rows below it get copied — which
    # must not make the session look like it emitted to both environments at once.
    straddling = "cccccccc-0000-0000-0000-000000000003"
    metric(conn, EARLY, session_id=straddling)
    metric(conn, LATE, session_id=straddling)
    metric(target, FLIP)

    copy(pg_url, target_url)

    assert "emitted to both environments" not in capsys.readouterr().out


def test_reports_and_skips_a_seat_whose_production_rows_predate_the_floor(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # A production row below the floor drags the seat's minimum below it, so `[floor, watermark)`
    # is empty and nothing is copyable. Left in the watermark set it would copy nothing while
    # verification compared 0 against 0 and reported the seat as matched.
    metric(conn, EARLY)
    metric(target, BELOW_FLOOR)
    metric(target, FLIP)

    copy(pg_url, target_url)

    out = capsys.readouterr().out
    assert f"raw.metrics: 1 seat(s) with a watermark at or below the floor: {SEAT}" in out
    assert "raw.metrics: 0 seat(s) flipped" in out
    assert "Verified raw.metrics: per-seat counts match for 0 seat(s)" in out
    assert emails(target, "raw.metrics", "ts") == [(SEAT, BELOW_FLOOR), (SEAT, FLIP)]


def test_a_column_mismatch_on_the_second_table_leaves_the_first_uncopied(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # Both column checks must pass before anything is copied: psycopg commits an open transaction
    # on any non-exception exit, so refusing mid-loop would land raw.metrics while stderr claimed
    # nothing was copied.
    metric(conn, EARLY)
    event(conn, EARLY)
    metric(target, FLIP)
    event(target, FLIP)
    conn.execute("ALTER TABLE raw.events ADD COLUMN pending_column TEXT")
    try:
        assert run(pg_url, target_url, "--execute") == 1
    finally:
        conn.execute("ALTER TABLE raw.events DROP COLUMN pending_column")

    assert "Refused: raw.events columns differ" in capsys.readouterr().err
    assert emails(target, "raw.metrics", "ts") == [(SEAT, FLIP)]


def test_a_verification_mismatch_rolls_production_back_and_skips_the_refresh(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Verification has to gate the commit, not follow it. Committing a short copy would collapse
    # the seat's watermark to the earliest copied row, so the missing rows fall outside every
    # future run's window and are stranded for good — the exit code would be the only trace.
    from tools import cutover_copy

    real = cutover_copy.seat_counts

    def inflate_the_source(db, table, time_column, marks):  # type: ignore[no-untyped-def]
        # Only the source connection runs autocommit, which is what tells the two apart here.
        counts = real(db, table, time_column, marks)
        return {email: n + 1 for email, n in counts.items()} if db.autocommit else counts

    monkeypatch.setattr(cutover_copy, "seat_counts", inflate_the_source)
    metric(conn, EARLY)
    metric(target, FLIP)

    assert run(pg_url, target_url, "--execute") == 1

    captured = capsys.readouterr()
    assert f"Verification FAILED raw.metrics {SEAT}: interim 2, production 1" in captured.err
    assert "Rolled back — production is unchanged" in captured.err
    assert "Refreshed production marts" not in captured.out
    assert emails(target, "raw.metrics", "ts") == [(SEAT, FLIP)]
    refreshed = target.execute("SELECT count(*) FROM marts.mart_refresh_log").fetchone()
    assert refreshed is not None and refreshed[0] == 0


def test_refuses_to_run_while_another_execute_holds_the_lock(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # Two concurrent runs would both read the pre-copy watermark and both copy the same rows, and
    # `raw.*` has no primary key and this tool has no delete, so those duplicates could not be
    # removed. A second connection holding the lock stands in for the other run.
    from tools.cutover_copy import LOCK_KEY

    metric(conn, EARLY)
    metric(target, FLIP)
    with psycopg.connect(target_url, autocommit=True) as other_run:
        other_run.execute("SELECT pg_advisory_lock(%s)", (LOCK_KEY,))

        assert run(pg_url, target_url, "--execute") == 1

    assert "Refused: another cutover_copy --execute is running" in capsys.readouterr().err
    assert emails(target, "raw.metrics", "ts") == [(SEAT, FLIP)]


def test_a_dry_run_is_not_blocked_by_the_lock(
    conn: psycopg.Connection, pg_url: str, target: psycopg.Connection, target_url: str
) -> None:
    # The lock guards writes only: a read-only dry-run must stay available while a copy is running.
    from tools.cutover_copy import LOCK_KEY

    metric(conn, EARLY)
    metric(target, FLIP)
    with psycopg.connect(target_url, autocommit=True) as other_run:
        other_run.execute("SELECT pg_advisory_lock(%s)", (LOCK_KEY,))

        assert run(pg_url, target_url) == 0


def test_refuses_when_source_and_target_are_the_same_database(
    conn: psycopg.Connection, pg_url: str, capsys: pytest.CaptureFixture[str]
) -> None:
    metric(conn, EARLY)

    assert run(pg_url, pg_url, "--execute") == 1

    assert "Refused: source and target are the same database" in capsys.readouterr().err
    assert emails(conn, "raw.metrics", "ts") == [(SEAT, EARLY)]


def test_refuses_when_interim_holds_a_column_production_lacks(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # Production one migration behind interim: an explicit column list read off production would
    # drop the extra column's values silently, so the copy refuses instead.
    metric(conn, EARLY)
    metric(target, FLIP)
    conn.execute("ALTER TABLE raw.metrics ADD COLUMN pending_column TEXT")
    try:
        assert run(pg_url, target_url, "--execute") == 1
    finally:
        conn.execute("ALTER TABLE raw.metrics DROP COLUMN pending_column")

    assert "Refused: raw.metrics columns differ" in capsys.readouterr().err
    assert emails(target, "raw.metrics", "ts") == [(SEAT, FLIP)]


def test_the_gap_report_separates_a_delivered_backlog_from_a_stranded_one(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The discrimination ``held_above`` cannot make (#415).

    Both seats below have a watermark collapsed onto their own interim floor, so both copy zero
    rows and both report every row as ``held_above``. Only one of them is actually short in
    production. The bucket counts read identically; the gap report does not.
    """
    # SEAT: a queued flush replayed the whole backlog through the repointed sink, so production
    # holds both rows already. Copying nothing is correct.
    metric(conn, EARLY)
    metric(conn, LATE)
    metric(target, EARLY)
    metric(target, LATE)
    # OTHER: the same collapse, but only the first row ever reached production. One row stranded.
    metric(conn, EARLY, email=OTHER)
    metric(conn, LATE, email=OTHER)
    metric(target, EARLY, email=OTHER)

    assert run(pg_url, target_url) == 0

    out = capsys.readouterr().out
    # Indistinguishable in the buckets: nothing copyable, four rows held above a watermark.
    assert "raw.metrics: 2 seat(s) flipped, 0 row(s) to copy" in out
    assert "4 row(s) at or above a watermark" in out
    # Distinguished by the gap report.
    assert "raw.metrics not in production: 1 row(s) above the floor across 1 seat(s)" in out
    assert f"  {OTHER}: 1 of 2 row(s) missing" in out
    assert SEAT not in out.split("not in production:")[1]


def test_the_gap_report_names_a_seat_production_has_never_seen(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # An unflipped seat and a row with no seat identity: neither is copyable, and they have
    # different owners — the first is #409's sweep target, the second is never swept at all.
    metric(conn, EARLY, email=OTHER)
    metric(conn, EARLY, email=None)
    metric(conn, EARLY)
    metric(target, FLIP)

    assert run(pg_url, target_url) == 0

    out = capsys.readouterr().out
    assert "raw.metrics not in production: 3 row(s) above the floor across 3 seat(s)" in out
    assert f"  {OTHER}: 1 of 1 row(s) missing — no production rows at all (#409 --sweep" in out
    assert "  (no user_email): 1 of 1 row(s) missing — never swept" in out
    # SEAT's row is short too — this run has not copied it yet — but production has seen the seat,
    # so it is neither a sweep target nor unexplained.
    assert f"  {SEAT}: 1 of 1 row(s) missing\n" in out


def test_the_gap_report_reflects_the_state_after_the_copy_not_before_it(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # On --execute the report is the run's closing verdict, printed after the commit: reporting
    # the pre-copy gap would name rows the same run had just delivered.
    metric(conn, EARLY)
    metric(target, FLIP)

    copy(pg_url, target_url)

    out = capsys.readouterr().out
    assert "raw.metrics: production holds every seat's interim rows above the floor" in out
    assert "raw.metrics not in production:" not in out


def test_a_rolled_back_run_reports_no_gap_verdict(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The verdict is only true of a committed run. After a rollback it would describe rows that
    # are no longer in production.
    from tools import cutover_copy

    real = cutover_copy.seat_counts

    def inflate_the_source(db, table, time_column, marks):  # type: ignore[no-untyped-def]
        counts = real(db, table, time_column, marks)
        return {email: n + 1 for email, n in counts.items()} if db.autocommit else counts

    monkeypatch.setattr(cutover_copy, "seat_counts", inflate_the_source)
    metric(conn, EARLY)
    metric(target, FLIP)

    assert run(pg_url, target_url, "--execute") == 1

    out = capsys.readouterr().out
    assert "production holds every seat's interim rows" not in out
    assert "not in production:" not in out


def test_refreshes_production_marts_after_the_copy(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    metric(conn, EARLY)
    metric(target, FLIP)

    copy(pg_url, target_url)

    assert "Refreshed production marts" in capsys.readouterr().out
    refreshed = target.execute("SELECT count(*) FROM marts.mart_refresh_log").fetchone()
    assert refreshed is not None and refreshed[0] > 0


# --sweep (#409, ADR-0021): the terminal sweep for seats production has never seen at all —
# not merely unflipped, but absent from watermarks() entirely. Rides along with the normal
# per-seat window copy in the same run rather than being a separate mode.


def test_sweep_copies_a_seats_whole_window_when_production_has_never_seen_it(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # #409's target: interim holds rows for this seat above the floor, and production's
    # watermarks() has no entry for it at all -- not unflipped-with-a-pending-watermark, never seen.
    quiet_interim(conn)
    metric(conn, EARLY)
    metric(conn, LATE)

    assert run(pg_url, target_url, "--execute", "--sweep") == 0

    out = capsys.readouterr().out
    assert f"raw.metrics: {SEAT} pre-copy watermark = infinity" in out
    assert emails(target, "raw.metrics", "ts") == [(SEAT, EARLY), (SEAT, LATE)]


def test_a_sweep_rerun_copies_nothing_further(
    conn: psycopg.Connection, pg_url: str, target: psycopg.Connection, target_url: str
) -> None:
    # Idempotent the same way the normal path is: once swept, the seat has production rows, so
    # it is no longer absent from watermarks() and the next run's window for it collapses.
    quiet_interim(conn)
    metric(conn, EARLY)
    metric(conn, LATE)

    copy(pg_url, target_url, "--sweep")
    copy(pg_url, target_url, "--sweep")

    assert emails(target, "raw.metrics", "ts") == [(SEAT, EARLY), (SEAT, LATE)]


def test_sweep_refuses_when_interim_has_written_within_the_last_24_hours(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # Write-quiet is the load-bearing guarantee (ADR-0021): a seed batch an hour old means interim
    # could still gain rows for this seat, so the sweep must refuse rather than risk stranding them.
    quiet_interim(conn, hours=1)
    metric(conn, EARLY)

    assert run(pg_url, target_url, "--execute", "--sweep") == 1

    assert "Refused" in capsys.readouterr().err
    assert emails(target, "raw.metrics", "ts") == []


def test_sweep_refuses_when_no_batch_has_ever_been_recorded(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # MAX(processed_at) is NULL with no rows at all -- quiet cannot be measured, so this refuses
    # too, conservatively (the issue did not cover this case explicitly).
    conn.execute("TRUNCATE meta.processed_batches")
    metric(conn, EARLY)

    assert run(pg_url, target_url, "--execute", "--sweep") == 1

    assert "Refused" in capsys.readouterr().err
    assert emails(target, "raw.metrics", "ts") == []


def test_sweep_leaves_an_already_flipped_seat_to_its_normal_window(
    conn: psycopg.Connection, pg_url: str, target: psycopg.Connection, target_url: str
) -> None:
    # Both ride in the same run: SEAT is already flipped, so --sweep must not touch it -- only its
    # normal watermark-bounded window moves. OTHER has no production rows at all -- a sweep target.
    quiet_interim(conn)
    metric(conn, EARLY)
    metric(conn, LATE)  # above SEAT's own watermark -- stays in interim either way
    metric(target, FLIP)
    metric(conn, EARLY, email=OTHER)

    copy(pg_url, target_url, "--sweep")

    assert emails(target, "raw.metrics", "ts") == [
        (SEAT, EARLY),
        (OTHER, EARLY),
        (SEAT, FLIP),
    ]


def test_sweep_does_not_target_a_seat_whose_watermark_predates_the_floor(
    conn: psycopg.Connection,
    pg_url: str,
    target: psycopg.Connection,
    target_url: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # A below-floor seat has a production row, so it is present in watermarks() and can never be a
    # sweep target -- unlike a seat production has never seen at all. The existing not-copyable
    # message gains a clause saying so.
    quiet_interim(conn)
    metric(conn, EARLY)
    metric(target, BELOW_FLOOR)

    assert run(pg_url, target_url, "--execute", "--sweep") == 0

    out = capsys.readouterr().out
    assert (
        f"raw.metrics: 1 seat(s) with a watermark at or below the floor: {SEAT} — a production"
        " row predates 2026-07-17, so nothing is copyable for them; not swept either — a"
        " production row means they are already in watermarks(), and sweep targets are seats"
        " production has never seen" in out
    )
    assert emails(target, "raw.metrics", "ts") == [(SEAT, BELOW_FLOOR)]


def test_sweep_never_copies_rows_with_no_user_email(
    conn: psycopg.Connection, pg_url: str, target: psycopg.Connection, target_url: str
) -> None:
    # Rows with no user_email carry no seat identity to derive a sweep target from, and cannot
    # participate in the watermark collapse a re-run relies on -- never swept, whatever the count
    # (ADR-0021's accepted residual).
    quiet_interim(conn)
    metric(conn, EARLY, email=None)

    copy(pg_url, target_url, "--sweep")

    assert emails(target, "raw.metrics", "ts") == []


def test_a_sweep_shaped_seat_is_untouched_without_the_flag(
    conn: psycopg.Connection, pg_url: str, target: psycopg.Connection, target_url: str
) -> None:
    # Regression guard: without --sweep, a seat with no production rows at all is skipped exactly
    # as it is today -- an unflipped seat, not a sweep target, because there is no --sweep target.
    metric(conn, EARLY)

    copy(pg_url, target_url)

    assert emails(target, "raw.metrics", "ts") == []
