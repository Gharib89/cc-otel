"""Copy interim's pre-flip telemetry into production, bounded per seat by the flip watermark.

Implements the raw half of the cutover data policy (#245, ADR-0020). Interim and production run
the same schema behind the same sink image, so this is an **identity copy** -- no mapping layer,
the reason ADR-0002's ban on translated history does not apply.

A seat's **flip watermark** is ``MIN(<event time>)`` over that seat's *production* rows: the moment
its machine started emitting to production. The copy moves interim rows in
``[2026-07-17, watermark)`` and nothing else, computed per table because the two tables name their
event time differently (``raw.metrics.ts``, ``raw.events.event_time``).

**Re-runnable by design, not as a nicety.** The flip is staggered, so seats arrive over days: a
seat with no production row yet has no watermark and is skipped, and a later run picks it up. There
is no delete step -- the one ADR-0020 describes is empty on every run by the definition of ``MIN``
(no production row sits below that seat's own minimum), and idempotency comes from the watermark
itself: once a seat's rows are copied, production's minimum drops to the earliest copied row and
the next run's window is ``[floor, floor)``. Duplicates are unreachable without any delete.

Interim is left untouched -- it stays the fallback until #248 Part B's gate opens.

Every run closes with the **cutover shortfall** per seat: how many of interim's rows above the
floor production demonstrably lacks. That is the progress measure, not the held-in-interim
buckets -- nothing is deleted from interim, so a copied row sits at or above its seat's collapsed
watermark forever and reads identically to a row that never arrived (#415).

    uv run python -m tools.cutover_copy
    uv run python -m tools.cutover_copy --execute
    uv run python -m tools.cutover_copy --execute --sweep
"""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Mapping
from datetime import datetime, timedelta
from typing import NamedTuple

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict

# ADR-0020's window floor: interim's own live telemetry effectively begins here, and it is
# ADR-0017's replay floor, so the promoted columns below it are permanently NULL.
FLOOR = datetime.fromisoformat("2026-07-17 00:00:00+00:00")

# Table -> its event-time column. The names diverge, so each table carries its own watermark set.
TABLES = (("raw.metrics", "ts"), ("raw.events", "event_time"))

# Session-level advisory lock on the target, taken for the length of an ``--execute``. Two
# concurrent runs would both read the pre-copy watermark and both copy the same rows, and those
# duplicates could not be removed afterwards: ``raw.*`` has no primary key (ADR-0017) and this tool
# has no delete. Arbitrary but fixed — the issue number and the window floor.
LOCK_KEY = 245_20260717

# ADR-0021's write-quiet gate for `--sweep`: refuse unless interim's last recorded batch is at
# least this old. Fixed, no `--force` twin -- sweeping early is a decision about permanent data
# placement whose failure mode is silent, and a knob invites lowering it under time pressure.
SWEEP_WRITE_QUIET_WINDOW = timedelta(hours=24)

# Source-side scratch holding the watermarks read off production, so one statement can apply every
# seat's own window. TEMP: it lives in the source session and needs no cleanup or schema rights.
# Always schema-qualified: unqualified, the initial `DROP TABLE IF EXISTS` would resolve through
# `search_path` to a permanent `public` table on interim, which this tool never writes to.
_MARKS = sql.SQL("pg_temp.{}").format(sql.Identifier("_flip_watermark"))


class Census(NamedTuple):
    """One table's interim rows from the floor up, split by what the watermarks admit."""

    to_copy: int
    held_unflipped: int
    unflipped_seats: int
    held_above: int
    held_no_email: int


class Gap(NamedTuple):
    """One seat's shortfall in production, against its interim total above the floor."""

    user_email: str | None
    short: int
    interim: int
    in_production: bool


def _connection_label(database_url: str) -> str:
    """Host, port and database — printed for both ends, and the whole of what the same-database
    refusal compares. The port is in it because a pair distinguished only by port is two databases:
    printing labels that read identically would tell an operator the opposite.
    """
    info = conninfo_to_dict(database_url)
    return " ".join(
        f"{label}={info.get(field, '(unset)')}"
        for label, field in (("host", "host"), ("port", "port"), ("database", "dbname"))
    )


def watermarks(conn: psycopg.Connection, table: str, time_column: str) -> dict[str, datetime]:
    """Each seat's flip watermark, read off production.

    Rows with no ``user_email`` are excluded: they carry no seat identity, so no window can be
    derived for them and their interim counterparts stay where they are.
    """
    rows = conn.execute(
        sql.SQL(
            "SELECT user_email, min({}) FROM {} WHERE user_email IS NOT NULL GROUP BY 1"
        ).format(sql.Identifier(time_column), sql.SQL(table))
    ).fetchall()
    return {row[0]: row[1] for row in rows}


def sweep_targets(
    source: psycopg.Connection, table: str, time_column: str, marks: Mapping[str, datetime]
) -> list[str]:
    """Seats interim holds rows for, above the floor, that production's ``watermarks()`` has never
    recorded at all (ADR-0021, `--sweep`).

    ``marks`` must be the dict as ``watermarks()`` returned it, before the below-floor filter drops
    anyone: a below-floor seat has a production row and so is already present here, and it must
    stay excluded from sweeping -- it could never self-exclude on a re-run otherwise, since its
    watermark never moves.
    """
    rows = source.execute(
        sql.SQL(
            "SELECT DISTINCT user_email FROM {table} WHERE user_email IS NOT NULL AND {tc} >= %s"
        ).format(table=sql.SQL(table), tc=sql.Identifier(time_column)),
        (FLOOR,),
    ).fetchall()
    return sorted(email for (email,) in rows if email not in marks)


def _interim_write_quiet_age(source: psycopg.Connection) -> timedelta | None:
    """Time since interim's last recorded batch, or ``None`` if none has ever been recorded.

    ``meta.processed_batches.processed_at`` defaults to ``now()`` on the server and is claimed by
    every batch that writes rows, so it is an exact "when did interim last gain rows" clock --
    unlike ``MAX(ts)``/``MAX(event_time)``, which are client-side and would read quiet during a
    late flush from a skewed clock.
    """
    row = source.execute("SELECT now() - MAX(processed_at) FROM meta.processed_batches").fetchone()
    assert row is not None  # noqa: S101 — aggregate-only SELECT always returns one row
    return row[0]


def _columns(conn: psycopg.Connection, table: str) -> list[str]:
    schema, name = table.split(".")
    rows = conn.execute(
        "SELECT column_name FROM information_schema.columns"
        " WHERE table_schema = %s AND table_name = %s ORDER BY ordinal_position",
        (schema, name),
    ).fetchall()
    return [row[0] for row in rows]


def _seed_watermarks(
    source: psycopg.Connection, marks: Mapping[str, datetime], sweep_emails: list[str]
) -> None:
    """(Re)create the watermark scratch table: one finite mark per flipped seat, plus one
    `timestamptz 'infinity'` row per sweep target (ADR-0021).

    Infinity compares greater than every finite timestamp, so it needs no branching anywhere the
    watermark table is joined. Cast in SQL rather than bound as a parameter: Postgres has no
    implicit text -> timestamptz cast, and there is no Python ``datetime`` value for infinity to
    pass instead.
    """
    source.execute(sql.SQL("DROP TABLE IF EXISTS {}").format(_MARKS))
    source.execute(
        sql.SQL(
            "CREATE TEMP TABLE {} (user_email TEXT PRIMARY KEY, watermark TIMESTAMPTZ NOT NULL)"
        ).format(_MARKS)
    )
    with source.cursor() as cur:
        cur.executemany(
            sql.SQL("INSERT INTO {} (user_email, watermark) VALUES (%s, %s)").format(_MARKS),
            list(marks.items()),
        )
    if sweep_emails:
        source.execute(
            sql.SQL("INSERT INTO {} SELECT unnest(%s::text[]), 'infinity'::timestamptz").format(
                _MARKS
            ),
            (sweep_emails,),
        )


def census(source: psycopg.Connection, table: str, time_column: str) -> Census:
    """Split interim's in-window rows against the seeded watermarks, in one pass.

    Everything not in ``to_copy`` stays in interim: an unflipped seat has no window yet, a row at
    or above its seat's watermark is post-flip interim traffic (a Claude Code process that had not
    restarted), and a row with no ``user_email`` has no seat to derive a window from. #248 Part B's
    row-count-verified ``pg_dump`` is what keeps those queryable after decommission. Under
    ``--sweep`` a sweep target is seeded with ``infinity``, so its rows land in ``to_copy`` and
    only below-floor seats remain in the unflipped bucket (ADR-0021).
    """
    row = source.execute(
        sql.SQL(
            "SELECT"
            " count(*) FILTER (WHERE w.user_email IS NOT NULL AND src.{tc} < w.watermark),"
            " count(*) FILTER (WHERE user_email IS NOT NULL AND w.user_email IS NULL),"
            " count(DISTINCT user_email) FILTER (WHERE w.user_email IS NULL),"
            " count(*) FILTER (WHERE w.user_email IS NOT NULL AND src.{tc} >= w.watermark),"
            " count(*) FILTER (WHERE user_email IS NULL)"
            " FROM {table} src LEFT JOIN {marks} w USING (user_email)"
            " WHERE src.{tc} >= %s"
        ).format(
            tc=sql.Identifier(time_column),
            table=sql.SQL(table),
            marks=_MARKS,
        ),
        (FLOOR,),
    ).fetchone()
    assert row is not None  # noqa: S101 — aggregate-only SELECT always returns one row
    return Census(*row)


def _rows_by_seat_day(
    conn: psycopg.Connection, table: str, time_column: str
) -> dict[tuple[str | None, datetime], int]:
    """Rows above the floor per ``(user_email, UTC day)``.

    The day grain is what makes the comparison honest. A flat per-seat count is blind by the
    seat's own post-flip production volume — an active seat holds thousands more rows in
    production than in interim, and that surplus silently absorbs any pre-flip rows the copy
    missed. Bucketing by day confines the overlap to the single day a seat's flip falls on, so a
    shortfall on every other day is real. ``AT TIME ZONE 'UTC'`` is explicit because
    ``date_trunc`` on a ``timestamptz`` otherwise reads the session's ``TimeZone``.
    """
    rows = conn.execute(
        sql.SQL(
            "SELECT user_email, date_trunc('day', {tc} AT TIME ZONE 'UTC'), count(*)"
            " FROM {table} WHERE {tc} >= %s GROUP BY 1, 2"
        ).format(table=sql.SQL(table), tc=sql.Identifier(time_column)),
        (FLOOR,),
    ).fetchall()
    return {(row[0], row[1]): row[2] for row in rows}


def seat_gaps(
    source: psycopg.Connection, target: psycopg.Connection, table: str, time_column: str
) -> list[Gap]:
    """Per seat, how many interim rows above the floor production demonstrably lacks (#415).

    The census buckets cannot answer "does production hold these rows?", which is the only
    question the cutover cares about. Nothing is ever deleted from interim, so a copied seat's
    rows stay there while its watermark collapses onto the earliest copied row — and they then
    re-report as ``held_above`` on every later run, indistinguishable from rows that never
    arrived. A returning seat whose collector replayed a queued batch through the repointed sink
    (ADR-0021) reads the same way, and for that seat copying nothing is *correct*. Comparing the
    two environments directly separates the three populations.

    The shortfall is a **lower bound**: ``sum(max(interim - production, 0))`` over the days the
    seat appears, so a production surplus on one day never cancels a shortfall on another. It is
    counts, not row identities — ``raw.*`` has no primary key (ADR-0017), so it says how many rows
    production lacks, never which. A detector, deliberately not a recovery cursor.
    """
    interim = _rows_by_seat_day(source, table, time_column)
    production = _rows_by_seat_day(target, table, time_column)
    seen = {email for email, _ in production}
    shortfall: dict[str | None, int] = {}
    totals: dict[str | None, int] = {}
    for (email, day), count in interim.items():
        shortfall[email] = shortfall.get(email, 0) + max(count - production.get((email, day), 0), 0)
        totals[email] = totals.get(email, 0) + count
    return [Gap(email, short, totals[email], email in seen) for email, short in shortfall.items()]


def report_gaps(source: psycopg.Connection, target: psycopg.Connection) -> None:
    """Print, per table, how many interim rows above the floor production is short, by seat."""
    for table, time_column in TABLES:
        short = [g for g in seat_gaps(source, target, table, time_column) if g.short]
        if not short:
            print(f"{table}: production holds every seat's interim rows above the floor")
            continue
        print(
            f"{table} not in production: {sum(g.short for g in short)} row(s) above the floor"
            f" across {len(short)} seat(s)"
        )
        for gap in sorted(short, key=lambda g: -g.short):
            line = (
                f"  {gap.user_email or '(no user_email)'}: {gap.short} of {gap.interim}"
                " row(s) missing"
            )
            if gap.user_email is None:
                line += " — never swept, no user_email to derive a seat from (ADR-0021)"
            elif not gap.in_production:
                line += " — no production rows at all (#409 --sweep target)"
            print(line)


def seat_counts(
    conn: psycopg.Connection, table: str, time_column: str, marks: Mapping[str, datetime | str]
) -> dict[str, int]:
    """Rows per seat inside that seat's ``[floor, watermark)`` window.

    The watermarks are the ones captured **before** the copy: afterwards production's own minimum
    has dropped to the earliest copied row, so re-deriving them here would compare empty windows
    and pass vacuously.

    ``mark`` may be a sweep target's ``"infinity"`` sentinel (ADR-0021) rather than a ``datetime``:
    the explicit ``::timestamptz`` cast is a no-op for the latter and makes the former a valid
    upper bound, since Postgres has no implicit text -> timestamptz cast to fall back on.
    """
    counts = {}
    for email, mark in marks.items():
        row = conn.execute(
            sql.SQL(
                "SELECT count(*) FROM {table}"
                " WHERE user_email = %s AND {tc} >= %s AND {tc} < %s::timestamptz"
            ).format(table=sql.SQL(table), tc=sql.Identifier(time_column)),
            (email, FLOOR, mark),
        ).fetchone()
        assert row is not None  # noqa: S101 — aggregate-only SELECT always returns one row
        counts[email] = row[0]
    return counts


def dual_sent_sessions(
    source: psycopg.Connection, target: psycopg.Connection, table: str, time_column: str
) -> list[str]:
    """Sessions that emitted to interim and production at once — ADR-0020's one open exception.

    The policy assumes disjoint row sets (each machine bakes exactly one collector endpoint) and
    hands detecting the exception here. A session merely *straddling* the flip is not one: its
    interim rows sit below the watermark and its production rows above, and the marts re-assemble
    it on ``session_id``. A dual-send is the same session above the watermark on **both** sides.
    Reported, never removed — nothing in the policy deletes production rows.
    """
    above = source.execute(
        sql.SQL(
            "SELECT DISTINCT src.session_id FROM {table} src JOIN {marks} w USING (user_email)"
            " WHERE src.session_id IS NOT NULL AND src.{tc} >= w.watermark"
        ).format(
            table=sql.SQL(table),
            marks=_MARKS,
            tc=sql.Identifier(time_column),
        )
    ).fetchall()
    if not above:
        return []
    both = target.execute(
        sql.SQL("SELECT DISTINCT session_id FROM {table} WHERE session_id = ANY(%s)").format(
            table=sql.SQL(table)
        ),
        ([row[0] for row in above],),
    ).fetchall()
    return sorted(str(row[0]) for row in both)


def copy_table(
    source: psycopg.Connection,
    target: psycopg.Connection,
    table: str,
    time_column: str,
    columns: list[str],
    marks: Mapping[str, datetime | str],
) -> int:
    """Stream one table's below-watermark rows source -> target; return the row count copied.

    A single client-side ``COPY ... TO STDOUT`` | ``COPY ... FROM STDIN`` pipe: no temp files, no
    PII on disk, and one statement per side so a failure copies nothing rather than a prefix.
    """
    if not marks:
        return 0
    projection = sql.SQL(", ").join(sql.SQL("src.{}").format(sql.Identifier(c)) for c in columns)
    column_list = sql.SQL(", ").join(sql.Identifier(c) for c in columns)
    out = sql.SQL(
        "COPY (SELECT {projection} FROM {table} src"
        " JOIN {marks} w USING (user_email)"
        " WHERE src.{time_column} >= %s AND src.{time_column} < w.watermark) TO STDOUT"
    ).format(
        projection=projection,
        table=sql.SQL(table),
        marks=_MARKS,
        time_column=sql.Identifier(time_column),
    )
    into = sql.SQL("COPY {table} ({column_list}) FROM STDIN").format(
        table=sql.SQL(table), column_list=column_list
    )
    with source.cursor() as reader, target.cursor() as writer:
        with reader.copy(out, (FLOOR,)) as stream, writer.copy(into) as sink:
            for block in stream:
                sink.write(block)
        return writer.rowcount


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--source-url", help="interim cc_otel; defaults to $INTERIM_DATABASE_URL")
    p.add_argument("--target-url", help="production cc_otel; defaults to $PROD_DATABASE_URL")
    p.add_argument("--execute", action="store_true", help="copy the rows (default: dry-run)")
    p.add_argument(
        "--sweep",
        action="store_true",
        help=(
            "also copy [floor, infinity) for seats production has never seen at all (ADR-0021);"
            " refuses unless interim has been write-quiet for >= 24h, no override"
        ),
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    source_url = args.source_url or os.environ.get("INTERIM_DATABASE_URL")
    target_url = args.target_url or os.environ.get("PROD_DATABASE_URL")
    if not source_url or not target_url:
        print(
            "Need both databases: pass --source-url/--target-url or set"
            " INTERIM_DATABASE_URL/PROD_DATABASE_URL",
            file=sys.stderr,
        )
        return 2
    # Before anything else: the two URLs differ by one word, and a swapped pair would copy
    # production's telemetry back into interim.
    print(f"Source (interim):    {_connection_label(source_url)}")
    print(f"Target (production): {_connection_label(target_url)}")

    if _connection_label(source_url) == _connection_label(target_url):
        print(
            f"Refused: source and target are the same database ({_connection_label(source_url)})"
            " — nothing copied",
            file=sys.stderr,
        )
        return 1

    captured: dict[str, dict[str, datetime | str]] = {}
    with (
        psycopg.connect(source_url, autocommit=True) as source,
        psycopg.connect(target_url) as target,
    ):
        # Checked first, before the lock or any per-table work: a sweep that will be refused should
        # write nothing, on a dry-run exactly as on --execute.
        if args.sweep:
            age = _interim_write_quiet_age(source)
            print(
                "Interim write-quiet check: no batch ever recorded"
                if age is None
                else f"Interim write-quiet check: last batch {age} ago"
            )
            if age is None:
                print(
                    "Refused: --sweep needs interim write-quiet for >= 24h and"
                    " meta.processed_batches has no batch recorded at all — write-quiet cannot"
                    " be measured; nothing written",
                    file=sys.stderr,
                )
                return 1
            if age < SWEEP_WRITE_QUIET_WINDOW:
                print(
                    f"Refused: interim last wrote {age} ago, under the 24h --sweep requires,"
                    " with no override — nothing written",
                    file=sys.stderr,
                )
                return 1

        # One writer at a time. Held for the whole run and released when this connection closes;
        # session-level, so the rollback path below does not drop it early. A dry-run never takes
        # it — it writes nothing, and must stay available while a copy is in flight.
        if args.execute:
            held = target.execute("SELECT pg_try_advisory_lock(%s)", (LOCK_KEY,)).fetchone()
            if held is None or not held[0]:
                print(
                    "Refused: another cutover_copy --execute is running against this production"
                    " database — run them one at a time; concurrent runs would both copy the same"
                    " rows and raw.* has no primary key to dedup on",
                    file=sys.stderr,
                )
                return 1

        # Every table's column parity is checked before *any* table is copied: psycopg commits an
        # open transaction on any non-exception exit, so refusing mid-loop would land the earlier
        # table while this said nothing was copied.
        table_columns = {}
        for table, _ in TABLES:
            table_columns[table] = _columns(target, table)
            if _columns(source, table) != table_columns[table]:
                print(
                    f"Refused: {table} columns differ between interim and production — an"
                    " explicit column list would drop the difference silently; nothing copied",
                    file=sys.stderr,
                )
                return 1

        for table, time_column in TABLES:
            all_marks = watermarks(target, table, time_column)
            # A production row below the floor drags that seat's minimum below it, leaving an empty
            # window. Dropped from the set rather than copied as a no-op, so verification cannot
            # report the seat as matched on 0 == 0 while its interim rows sit there untouched.
            below_floor = sorted(email for email, mark in all_marks.items() if mark <= FLOOR)
            if below_floor:
                message = (
                    f"{table}: {len(below_floor)} seat(s) with a watermark at or below the floor:"
                    f" {', '.join(below_floor)} — a production row predates {FLOOR:%Y-%m-%d},"
                    " so nothing is copyable for them"
                )
                if args.sweep:
                    # A below-floor seat has a production row -- it is present in `all_marks` -- so
                    # it can never be a sweep target the way an entirely unseen seat is.
                    message += (
                        "; not swept either — a production row means they are already in"
                        " watermarks(), and sweep targets are seats production has never seen"
                    )
                print(message)
            dropped = set(below_floor)
            finite_marks = {e: m for e, m in all_marks.items() if e not in dropped}
            marks: dict[str, datetime | str] = dict(finite_marks)

            sweep_emails: list[str] = []
            if args.sweep:
                # Computed from all_marks, before the below-floor filter: a below-floor seat must
                # stay excluded from sweeping too, and it is already absent from `marks` above.
                sweep_emails = sweep_targets(source, table, time_column, all_marks)
                for email in sweep_emails:
                    marks[email] = "infinity"

            captured[table] = marks
            _seed_watermarks(source, finite_marks, sweep_emails)
            if args.sweep:
                # Run evidence, not a recovery cursor: records which window this run moved, per
                # seeded seat. No state is persisted from it.
                for email in sorted(marks):
                    print(f"{table}: {email} pre-copy watermark = {marks[email]}")

            counted = census(source, table, time_column)
            # A sweep target is by definition never flipped (CONTEXT.md), so it is counted apart.
            flipped = f"{len(finite_marks)} seat(s) flipped"
            if args.sweep:
                flipped += f" + {len(sweep_emails)} sweep target(s)"
            print(f"{table}: {flipped}, {counted.to_copy} row(s) to copy")
            print(
                f"{table} held in interim: {counted.held_unflipped} row(s) for"
                f" {counted.unflipped_seats} unflipped seat(s), {counted.held_above} row(s) at or"
                f" above a watermark, {counted.held_no_email} row(s) with no user_email"
            )
            if args.execute:
                # Probed *before* the copy: afterwards this run's own copied rows would make every
                # straddling session look as if it had emitted to both environments.
                dual = dual_sent_sessions(source, target, table, time_column)
                if dual:
                    print(
                        f"{table}: {len(dual)} session(s) emitted to both environments:"
                        f" {', '.join(dual)}"
                    )
                copied = copy_table(source, target, table, time_column, table_columns[table], marks)
                print(f"{table}: copied {copied} row(s) for {len(marks)} seat(s)")

        if not args.execute:
            # State as it stands: what a run would leave behind is this, less the to_copy above.
            report_gaps(source, target)
            print("Dry-run — nothing written; pass --execute to copy")
            return 0

        # Verification gates the commit rather than following it. The counts already see the copied
        # rows inside this transaction, and a mismatch that had been committed would be permanent:
        # the copied rows collapse each seat's watermark, so the missing ones fall outside every
        # future run's window. Rolling back keeps them where a re-run can still reach them.
        mismatches: list[str] = []
        for table, time_column in TABLES:
            marks = captured[table]
            source_counts = seat_counts(source, table, time_column, marks)
            target_counts = seat_counts(target, table, time_column, marks)
            failed = [
                f"Verification FAILED {table} {email}: interim {source_counts[email]},"
                f" production {target_counts[email]}"
                for email in marks
                if source_counts[email] != target_counts[email]
            ]
            mismatches.extend(failed)
            if not failed:
                print(f"Verified {table}: per-seat counts match for {len(marks)} seat(s)")

        if mismatches:
            target.rollback()
            for line in mismatches:
                print(line, file=sys.stderr)
            print(
                "Rolled back — production is unchanged and interim still holds every row;"
                " re-run once the cause is understood",
                file=sys.stderr,
            )
            return 1
        # Both tables in one transaction: a failure leaves production exactly as it was, and the
        # next run recomputes identical watermarks.
        target.commit()

        # The run's closing verdict, and only true of a committed run — reported after the commit
        # so it names what is still missing rather than rows this run has just delivered.
        report_gaps(source, target)

    # The rows are committed, so a refresh failure costs freshness rather than data — pg_cron's
    # hourly marts.refresh_all() reconciles either way.
    try:
        with psycopg.connect(target_url, autocommit=True) as refresher:
            refresher.execute("SELECT marts.refresh_all()")
    except psycopg.Error as err:
        print(
            f"Warning: production marts not refreshed ({err}) — the hourly refresh will reconcile",
            file=sys.stderr,
        )
    else:
        print("Refreshed production marts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
