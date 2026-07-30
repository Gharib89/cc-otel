"""The `owner_email_mismatch` DQ finding (#372, decided in #364): a session whose
`process_owner` disagrees with the local-part of its ITWorx `user_email`.

Both halves are asserted. Without the silent half zero rows is unfalsifiable — on today's
fleet every owner-bearing session agrees, so a wrong rule and a working rule produce
identical output.
"""

from __future__ import annotations

import psycopg
from _helpers import ins_event, ins_metric

S1 = "aaaaaaaa-0000-0000-0000-000000000001"
S2 = "aaaaaaaa-0000-0000-0000-000000000002"

# The five real agreeing pairs measured on interim (#364).
AGREEING = [
    ("Hadeel.Sharaf", "hadeel.sharaf@itworx.com"),
    ("Kareem.Elakkad", "kareem.elakkad@itworx.com"),
    ("Engy.Salem", "engy.salem@itworx.com"),
    ("Safaa.Saied", "safaa.saied@itworx.com"),
    ("Ahmed.Gharib", "ahmed.gharib@itworx.com"),
]


def emit_metric(conn: psycopg.Connection, session_id: str, email: str, owner: str | None) -> None:
    ins_metric(
        conn,
        ts="2026-07-20T10:00:00Z",
        metric_name="claude_code.session.count",
        metric_type="sum",
        value=1,
        value_kind="sum_delta",
        user_email=email,
        session_id=session_id,
        process_owner=owner,
    )


def emit_event(conn: psycopg.Connection, session_id: str, email: str, owner: str | None) -> None:
    ins_event(
        conn,
        event_time="2026-07-20T11:00:00Z",
        event_name="api_request",
        user_email=email,
        session_id=session_id,
        process_owner=owner,
    )


def findings(conn: psycopg.Connection) -> list[tuple[int, dict]]:
    conn.execute("SELECT marts.refresh_all()")
    return conn.execute(
        "SELECT row_count, details FROM marts.dq_finding"
        " WHERE finding_type = 'owner_email_mismatch'"
        " ORDER BY details ->> 'session_id'"
    ).fetchall()


def test_mismatch_produces_one_finding_per_session_across_both_raw_tables(conn):
    # Two records, one metric and one event, inside a single session: process.owner is a
    # resource attribute, so it rides both signals and the finding must not double-count.
    emit_metric(conn, S1, "hadeel.sharaf@itworx.com", "Administrator")
    emit_event(conn, S1, "hadeel.sharaf@itworx.com", "Administrator")

    rows = findings(conn)
    assert len(rows) == 1
    row_count, details = rows[0]
    assert row_count == 2
    assert details["session_id"] == S1
    assert details["activity_date"] == "2026-07-20"
    assert details["process_owner"] == "Administrator"
    assert details["user_email"] == "hadeel.sharaf@itworx.com"
    assert details["record_count"] == 2


def test_two_mismatching_sessions_are_two_findings(conn):
    emit_metric(conn, S1, "hadeel.sharaf@itworx.com", "Administrator")
    emit_metric(conn, S2, "engy.salem@itworx.com", "DESKTOP-4F2K1")

    assert [d["session_id"] for _, d in findings(conn)] == sorted([S1, S2])


def test_the_five_real_agreeing_pairs_stay_silent(conn):
    # Case and surrounding whitespace are normalised away: the owner arrives as the OS
    # account name (`First.Last`), the email lower-cased, and neither difference is a
    # mismatch.
    for i, (owner, email) in enumerate(AGREEING):
        emit_metric(conn, f"bbbbbbbb-0000-0000-0000-00000000000{i}", email, f"  {owner} ")

    assert findings(conn) == []


def test_personal_address_is_excluded_not_reported(conn):
    # A personal address can never equal a `First.Last` machine account, so an unscoped
    # rule would fire forever on an expected condition. ADR-0011 owns that reading.
    emit_metric(conn, S1, "rihamfhahmed@gmail.com", "Riham.Fathy")

    assert findings(conn) == []


def test_null_owner_is_not_a_mismatch(conn):
    # The CLI — 99.6% of records — never emits process.owner. Absence is emitter
    # behaviour, not evidence.
    emit_metric(conn, S1, "hadeel.sharaf@itworx.com", None)
    emit_event(conn, S1, "hadeel.sharaf@itworx.com", None)

    assert findings(conn) == []
