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

    uv run python -m tools.cutover_copy
    uv run python -m tools.cutover_copy --execute
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime
from typing import NamedTuple

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict

# ADR-0020's window floor: interim's own live telemetry effectively begins here, and it is
# ADR-0017's replay floor, so the promoted columns below it are permanently NULL.
FLOOR = datetime.fromisoformat("2026-07-17 00:00:00+00:00")

# Table -> its event-time column. The names diverge, so each table carries its own watermark set.
TABLES = (("raw.metrics", "ts"), ("raw.events", "event_time"))

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


def _connection_label(database_url: str) -> str:
    info = conninfo_to_dict(database_url)
    return f"host={info.get('host', '(unset)')} database={info.get('dbname', '(unset)')}"


def _identity(database_url: str) -> tuple[str, str, str]:
    """Host, port and database — what makes two URLs the same server, port included so a pair
    distinguished only by port (two local containers) is not mistaken for one database."""
    info = conninfo_to_dict(database_url)
    return (
        str(info.get("host", "")),
        str(info.get("port", "")),
        str(info.get("dbname", "")),
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


def _columns(conn: psycopg.Connection, table: str) -> list[str]:
    schema, name = table.split(".")
    rows = conn.execute(
        "SELECT column_name FROM information_schema.columns"
        " WHERE table_schema = %s AND table_name = %s ORDER BY ordinal_position",
        (schema, name),
    ).fetchall()
    return [row[0] for row in rows]


def _seed_watermarks(source: psycopg.Connection, marks: dict[str, datetime]) -> None:
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


def census(source: psycopg.Connection, table: str, time_column: str) -> Census:
    """Split interim's in-window rows against the seeded watermarks, in one pass.

    Everything not in ``to_copy`` stays in interim: an unflipped seat has no window yet, a row at
    or above its seat's watermark is post-flip interim traffic (a Claude Code process that had not
    restarted), and a row with no ``user_email`` has no seat to derive a window from. #248 Part B's
    row-count-verified ``pg_dump`` is what keeps those queryable after decommission.
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


def seat_counts(
    conn: psycopg.Connection, table: str, time_column: str, marks: dict[str, datetime]
) -> dict[str, int]:
    """Rows per seat inside that seat's ``[floor, watermark)`` window.

    The watermarks are the ones captured **before** the copy: afterwards production's own minimum
    has dropped to the earliest copied row, so re-deriving them here would compare empty windows
    and pass vacuously.
    """
    counts = {}
    for email, mark in marks.items():
        row = conn.execute(
            sql.SQL(
                "SELECT count(*) FROM {table} WHERE user_email = %s AND {tc} >= %s AND {tc} < %s"
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
    marks: dict[str, datetime],
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

    if _identity(source_url) == _identity(target_url):
        print(
            f"Refused: source and target are the same database ({_connection_label(source_url)})"
            " — nothing copied",
            file=sys.stderr,
        )
        return 1

    captured: dict[str, dict[str, datetime]] = {}
    with (
        psycopg.connect(source_url, autocommit=True) as source,
        psycopg.connect(target_url) as target,
    ):
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
            marks = watermarks(target, table, time_column)
            # A production row below the floor drags that seat's minimum below it, leaving an empty
            # window. Dropped from the set rather than copied as a no-op, so verification cannot
            # report the seat as matched on 0 == 0 while its interim rows sit there untouched.
            below_floor = sorted(email for email, mark in marks.items() if mark <= FLOOR)
            if below_floor:
                print(
                    f"{table}: {len(below_floor)} seat(s) with a watermark at or below the floor:"
                    f" {', '.join(below_floor)} — a production row predates {FLOOR:%Y-%m-%d},"
                    " so nothing is copyable for them"
                )
                marks = {e: m for e, m in marks.items() if e not in set(below_floor)}
            captured[table] = marks
            _seed_watermarks(source, marks)
            counted = census(source, table, time_column)
            print(f"{table}: {len(marks)} seat(s) flipped, {counted.to_copy} row(s) to copy")
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
            print("Dry-run — nothing written; pass --execute to copy")
            return 0
        # Both tables in one transaction: a failure leaves production exactly as it was, and the
        # next run recomputes identical watermarks.
        target.commit()

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

    for line in mismatches:
        print(line, file=sys.stderr)

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
    return 1 if mismatches else 0


if __name__ == "__main__":
    sys.exit(main())
