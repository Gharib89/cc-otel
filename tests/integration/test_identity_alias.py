"""Linked identities (#320, parent #303, ADR-0011): derived aliases, the operator override,
and the scoping address on marts.dim_user.

Every assertion reads the derived table, marts.dim_user or marts.dq_finding — never the shape
of the derivation SQL. The link governs visibility only: nothing is merged, so both identities
keep their own dim_user row and their own emitting address throughout.
"""

from __future__ import annotations

import psycopg
from _helpers import ins_event, ins_metric

S1 = "11111111-1111-1111-1111-111111111111"
S2 = "22222222-2222-2222-2222-222222222222"
S3 = "33333333-3333-3333-3333-333333333333"
S4 = "44444444-4444-4444-4444-444444444444"

CORP = "dev.one@itworx.com"
CORP_OTHER = "dev.two@itworx.com"
PERSONAL = "devone@gmail.com"


def emit(conn: psycopg.Connection, session_id: str, email: str | None, day: str = "13") -> None:
    """One telemetry row for `email` inside `session_id` — the alias rule's only evidence."""
    ins_metric(
        conn,
        ts=f"2026-07-{day}T10:00:00Z",
        metric_name="claude_code.session.count",
        metric_type="sum",
        value=1,
        value_kind="sum_delta",
        user_email=email,
        session_id=session_id,
    )


def emit_event(conn: psycopg.Connection, session_id: str, email: str, day: str = "13") -> None:
    """The same evidence carried by an event row — both raw tables feed the rule."""
    ins_event(
        conn,
        event_time=f"2026-07-{day}T10:00:00Z",
        event_name="api_request",
        user_email=email,
        session_id=session_id,
    )


def refresh(conn: psycopg.Connection) -> None:
    conn.execute("SELECT marts.refresh_all()")


def derived(conn: psycopg.Connection) -> list[tuple[str, str, int]]:
    return conn.execute(
        "SELECT personal_email, corporate_email, shared_sessions"
        " FROM staging.stg_identity_alias ORDER BY personal_email"
    ).fetchall()


def scoping(conn: psycopg.Connection) -> dict[str, str]:
    """{emitting address: scoping address} for every dim_user row."""
    return dict(conn.execute("SELECT user_email, rls_email FROM marts.dim_user").fetchall())


def unresolved(conn: psycopg.Connection) -> list[tuple[int, dict]]:
    return conn.execute(
        "SELECT row_count, details FROM marts.dq_finding"
        " WHERE finding_type = 'identity_alias_unresolved' ORDER BY details ->> 'user_email'"
    ).fetchall()


def manual(conn: psycopg.Connection, personal: str, corporate: str | None) -> None:
    conn.execute(
        "INSERT INTO ref.identity_alias (personal_email, corporate_email, added_by, notes)"
        " VALUES (%s, %s, 'test', 'fixture')",
        (personal, corporate),
    )


# --- the three derivation guards ---------------------------------------------


def test_two_shared_sessions_yield_a_link(conn):
    emit(conn, S1, CORP)
    emit(conn, S1, PERSONAL)
    # The second session's evidence arrives as events, not metrics: the rule reads both raw
    # tables, and a session split across them is the ordinary case for one process.
    emit_event(conn, S2, CORP)
    emit_event(conn, S2, PERSONAL)
    refresh(conn)

    assert derived(conn) == [(PERSONAL, CORP, 2)]
    # Nothing is merged: two dim_user rows survive, the personal one scoped as the corporate one.
    assert scoping(conn) == {CORP: CORP, PERSONAL: CORP}
    # Resolved, so no worklist entry.
    assert unresolved(conn) == []


def test_one_shared_session_yields_no_link(conn):
    emit(conn, S1, CORP)
    emit(conn, S1, PERSONAL)
    refresh(conn)

    assert derived(conn) == []
    assert scoping(conn) == {CORP: CORP, PERSONAL: PERSONAL}


def test_conflicting_corporate_partner_yields_no_link(conn):
    # Two shared sessions with one corporate address would link on their own; a single session
    # with a second corporate address is a conflict, and the conflict outranks the count.
    for session in (S1, S2):
        emit(conn, session, CORP)
        emit(conn, session, PERSONAL)
    emit(conn, S3, CORP_OTHER)
    emit(conn, S3, PERSONAL)
    refresh(conn)

    assert derived(conn) == []
    assert scoping(conn)[PERSONAL] == PERSONAL


def test_corporate_to_corporate_yields_no_link(conn):
    # A shared terminal: both addresses are corporate, both already have an HR row.
    for session in (S1, S2):
        emit(conn, session, CORP)
        emit(conn, session, CORP_OTHER)
    refresh(conn)

    assert derived(conn) == []
    assert scoping(conn) == {CORP: CORP, CORP_OTHER: CORP_OTHER}


# --- operator precedence -----------------------------------------------------


def test_manual_alias_outranks_the_derived_pair(conn):
    for session in (S1, S2):
        emit(conn, session, CORP)
        emit(conn, session, PERSONAL)
    manual(conn, PERSONAL, CORP_OTHER)
    refresh(conn)

    # The derived pair is not rewritten — precedence lives in dim_user, so the guess stays
    # auditable next to the correction.
    assert derived(conn) == [(PERSONAL, CORP, 2)]
    assert scoping(conn)[PERSONAL] == CORP_OTHER


def test_manual_row_with_null_corporate_suppresses_the_derived_pair(conn):
    for session in (S1, S2):
        emit(conn, session, CORP)
        emit(conn, session, PERSONAL)
    manual(conn, PERSONAL, None)
    refresh(conn)

    assert derived(conn) == [(PERSONAL, CORP, 2)]
    assert scoping(conn)[PERSONAL] == PERSONAL
    # A human already ruled on this address; re-reporting it would never drain the worklist.
    assert unresolved(conn) == []


# --- the worklist ------------------------------------------------------------


def test_unresolved_personal_identity_produces_a_dq_finding(conn):
    emit(conn, S1, PERSONAL, day="13")
    emit(conn, S2, PERSONAL, day="15")
    # A corporate emitter without a seat is seat_emitter_without_seat's business, and no alias
    # rule could ever resolve it; a null-email row collapses into the (unknown) member.
    emit(conn, S3, CORP)
    emit(conn, S4, None)
    refresh(conn)

    rows = unresolved(conn)
    assert len(rows) == 1
    row_count, details = rows[0]
    assert row_count == 2  # activity days
    assert details["user_email"] == PERSONAL
    assert details["first_activity_date"] == "2026-07-13"
    assert details["last_activity_date"] == "2026-07-15"


def test_manual_only_link_resolves_an_identity_with_no_shared_session(conn):
    emit(conn, S1, CORP)
    emit(conn, S2, PERSONAL)
    manual(conn, PERSONAL, CORP)
    refresh(conn)

    assert derived(conn) == []
    assert scoping(conn)[PERSONAL] == CORP
    assert unresolved(conn) == []
