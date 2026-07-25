"""Derived seat history (#293, parent #290, ADR-0009): the shared derivation view, the three
seat marts it feeds, and the six seat data-quality findings.

Drops are loaded through the real loader CLI against throwaway Postgres, and every assertion
reads mart contents — never the shape of the derivation SQL, which is expected to change when
IS adds a status column (#291).
"""

from __future__ import annotations

from pathlib import Path

import psycopg
from _helpers import ins_event, ins_metric

from tools.roster_load import main

HEADER = "email,Team,subscription_1,assignment_date_1"
SEAT_MARTS = ("dim_seat", "dim_seat_current", "fact_seat_day")


def seat(email: str, tier: str = "Claude Standard", assigned: str = "", org: str = "ITWorx") -> str:
    return f"{email},{org},{tier},{assigned}"


def roster(tmp_path: Path, *rows: str, name: str, header: str = HEADER) -> Path:
    """Write a roster CSV, stamped with an unmapped `export_id` column carrying the file name.

    The stamp lands in `extra` and nothing here reads it. It exists because the loader refuses
    byte-identical content by hash, and a fixture where two drops hold the same handful of
    unchanged seats would otherwise be rejected as a re-ingest.
    """
    path = tmp_path / name
    stamped = (f"{row},{name}" for row in rows)
    path.write_text("\n".join((f"{header},export_id", *stamped)) + "\n", encoding="utf-8")
    return path


def load(pg_url: str, path: Path, as_of: str) -> None:
    """Load a drop through the real CLI.

    Always ``--force``: these fixtures are a handful of seats, so an ordinary tier change or
    revocation empties a tier or an organization and trips the loader's whole-file-truncation
    guards. Those guards are the loader's concern and are covered in ``test_roster_load.py``;
    here they would only stop the derivation under test from ever seeing a second drop.
    """
    argv = ["--file", str(path), "--as-of", as_of, "--database-url", pg_url, "--execute", "--force"]
    assert main(argv) == 0


def refresh(conn: psycopg.Connection) -> None:
    conn.execute("SELECT marts.refresh_all()")


def one(conn: psycopg.Connection, sql: str):
    row = conn.execute(sql).fetchone()
    assert row is not None
    return row


def all_(conn: psycopg.Connection, sql: str):
    return conn.execute(sql).fetchall()


def intervals(conn: psycopg.Connection):
    return all_(
        conn,
        "SELECT user_email, seat_tier, anthropic_org_name, valid_from::text, valid_to::text,"
        " valid_from_basis FROM marts.dim_seat ORDER BY user_email, valid_from",
    )


def finding(conn: psycopg.Connection, finding_type: str):
    return all_(
        conn,
        "SELECT row_count, details FROM marts.dq_finding"
        f" WHERE finding_type = '{finding_type}' ORDER BY details ->> 'user_email'",
    )


# --- dating rules -----------------------------------------------------------


def test_a_seat_opens_from_its_assignment_date(conn, pg_url, tmp_path):
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d1.csv"),
         "2026-05-20")
    refresh(conn)

    assert intervals(conn) == [
        ("a@itworx.com", "Standard", "ITWorx", "2026-04-08", None, "source-dated")
    ]


def test_a_seat_with_no_assignment_date_opens_observation_dated(conn, pg_url, tmp_path):
    load(pg_url, roster(tmp_path, seat("a@itworx.com"), name="d1.csv"), "2026-05-20")
    refresh(conn)

    assert intervals(conn) == [
        ("a@itworx.com", "Standard", "ITWorx", "2026-05-20", None, "observation-dated")
    ]


def test_a_tier_change_with_a_moved_assignment_date_is_source_dated(conn, pg_url, tmp_path):
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d1.csv"),
         "2026-05-20")
    load(
        pg_url,
        roster(tmp_path, seat("a@itworx.com", "Claude Premium", "6/1/2026"), name="d2.csv"),
        "2026-06-20",
    )
    refresh(conn)

    assert intervals(conn) == [
        ("a@itworx.com", "Standard", "ITWorx", "2026-04-08", "2026-06-01", "source-dated"),
        ("a@itworx.com", "Premium", "ITWorx", "2026-06-01", None, "source-dated"),
    ]


def test_a_tier_change_without_a_moved_assignment_date_is_observation_dated(
    conn, pg_url, tmp_path
):
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d1.csv"),
         "2026-05-20")
    load(
        pg_url,
        roster(tmp_path, seat("a@itworx.com", "Claude Premium", "4/8/2026"), name="d2.csv"),
        "2026-06-20",
    )
    refresh(conn)

    assert intervals(conn) == [
        ("a@itworx.com", "Standard", "ITWorx", "2026-04-08", "2026-06-20", "source-dated"),
        ("a@itworx.com", "Premium", "ITWorx", "2026-06-20", None, "observation-dated"),
    ]


def test_a_seat_absent_from_a_later_drop_closes_at_that_drops_as_of(conn, pg_url, tmp_path):
    load(
        pg_url,
        roster(
            tmp_path,
            seat("a@itworx.com", assigned="4/8/2026"),
            seat("b@itworx.com", assigned="4/9/2026"),
            name="d1.csv",
        ),
        "2026-05-20",
    )
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d2.csv"),
         "2026-06-20")
    refresh(conn)

    assert intervals(conn) == [
        ("a@itworx.com", "Standard", "ITWorx", "2026-04-08", None, "source-dated"),
        ("b@itworx.com", "Standard", "ITWorx", "2026-04-09", "2026-06-20", "source-dated"),
    ]


def test_an_organization_move_opens_a_new_interval(conn, pg_url, tmp_path):
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d1.csv"),
         "2026-05-20")
    load(
        pg_url,
        roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026", org="ITWorx2"), name="d2.csv"),
        "2026-06-20",
    )
    refresh(conn)

    assert intervals(conn) == [
        ("a@itworx.com", "Standard", "ITWorx", "2026-04-08", "2026-06-20", "source-dated"),
        ("a@itworx.com", "Standard", "ITWorx2", "2026-06-20", None, "observation-dated"),
    ]


# --- arrival order and repair ----------------------------------------------


def _three_drops(tmp_path: Path) -> list[tuple[Path, str]]:
    return [
        (roster(tmp_path, seat("e@itworx.com", assigned="4/8/2026"), name="d1.csv"), "2026-05-20"),
        (
            roster(tmp_path, seat("e@itworx.com", "Claude Premium", "6/1/2026"), name="d2.csv"),
            "2026-06-20",
        ),
        (
            roster(tmp_path, seat("e@itworx.com", "Claude Premium", "6/1/2026"), name="d3.csv"),
            "2026-07-20",
        ),
    ]


def test_loading_drops_out_of_as_of_order_produces_identical_history(conn, pg_url, tmp_path):
    drops = _three_drops(tmp_path)
    for path, as_of in drops:
        load(pg_url, path, as_of)
    refresh(conn)
    in_order = intervals(conn)

    conn.execute("TRUNCATE ref.roster_drop CASCADE")
    # Newest first: every later drop trips the as-of ordering guard, which is exactly the
    # arrival pattern a manual, irregular ingest produces.
    for path, as_of in (drops[2], drops[0], drops[1]):
        load(pg_url, path, as_of)
    refresh(conn)

    assert intervals(conn) == in_order
    assert in_order == [
        ("e@itworx.com", "Standard", "ITWorx", "2026-04-08", "2026-06-01", "source-dated"),
        ("e@itworx.com", "Premium", "ITWorx", "2026-06-01", None, "source-dated"),
    ]


def test_deleting_a_bad_drop_and_refreshing_restores_correct_history(conn, pg_url, tmp_path):
    load(
        pg_url,
        roster(
            tmp_path,
            seat("a@itworx.com", assigned="4/8/2026"),
            seat("b@itworx.com", assigned="4/9/2026"),
            name="d1.csv",
        ),
        "2026-05-20",
    )
    # A truncated export drops b; the operator forces it through, then spots the error.
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="bad.csv"),
         "2026-06-20")
    load(
        pg_url,
        roster(
            tmp_path,
            seat("a@itworx.com", assigned="4/8/2026"),
            seat("b@itworx.com", assigned="4/9/2026"),
            name="d3.csv",
        ),
        "2026-07-20",
    )
    refresh(conn)
    assert len(intervals(conn)) == 3  # a open, b closed, b reopened

    conn.execute("DELETE FROM ref.roster_drop WHERE source_filename = 'bad.csv'")
    refresh(conn)

    assert intervals(conn) == [
        ("a@itworx.com", "Standard", "ITWorx", "2026-04-08", None, "source-dated"),
        ("b@itworx.com", "Standard", "ITWorx", "2026-04-09", None, "source-dated"),
    ]


def test_a_same_day_corrected_re_export_supersedes_the_drop_it_corrects(conn, pg_url, tmp_path):
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d1.csv"),
         "2026-05-20")
    load(
        pg_url,
        roster(tmp_path, seat("a@itworx.com", "Claude Premium", "4/8/2026"), name="fixed.csv"),
        "2026-05-20",
    )
    refresh(conn)

    assert intervals(conn) == [
        ("a@itworx.com", "Premium", "ITWorx", "2026-04-08", None, "source-dated")
    ]


# --- the daily grain and the date spine -------------------------------------


def test_daily_fact_row_count_equals_the_sum_of_interval_day_spans(conn, pg_url, tmp_path):
    load(
        pg_url,
        roster(
            tmp_path,
            seat("a@itworx.com", assigned="4/8/2026"),
            seat("b@itworx.com", assigned="4/9/2026"),
            name="d1.csv",
        ),
        "2026-05-20",
    )
    load(pg_url, roster(tmp_path, seat("a@itworx.com", "Claude Premium", "6/1/2026"),
                        name="d2.csv"), "2026-06-20")
    refresh(conn)

    spans = one(
        conn,
        "SELECT SUM(COALESCE(valid_to, CURRENT_DATE + 1) - valid_from)::bigint FROM marts.dim_seat",
    )[0]
    assert one(conn, "SELECT COUNT(*) FROM marts.fact_seat_day")[0] == spans


def test_no_daily_fact_row_falls_outside_the_date_dimension(conn, pg_url, tmp_path):
    ins_metric(
        conn,
        ts="2026-07-01T10:00:00Z",
        metric_name="claude_code.session.count",
        metric_type="sum",
        value=1,
        value_kind="sum_delta",
        user_email="a@itworx.com",
    )
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d1.csv"),
         "2026-05-20")
    refresh(conn)

    orphans = one(
        conn,
        "SELECT COUNT(*) FROM marts.fact_seat_day f"
        " LEFT JOIN marts.dim_date d ON f.date_day = d.date_day WHERE d.date_day IS NULL",
    )[0]
    assert orphans == 0


def test_the_date_dimension_floor_accounts_for_the_earliest_assignment_date(
    conn, pg_url, tmp_path
):
    ins_metric(
        conn,
        ts="2026-07-01T10:00:00Z",
        metric_name="claude_code.session.count",
        metric_type="sum",
        value=1,
        value_kind="sum_delta",
        user_email="a@itworx.com",
    )
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d1.csv"),
         "2026-05-20")
    refresh(conn)

    assert one(conn, "SELECT MIN(date_day)::text FROM marts.dim_date")[0] == "2026-04-08"


def test_the_date_dimension_floor_falls_back_to_the_drop_as_of_with_no_assignment_dates(
    conn, pg_url, tmp_path
):
    load(pg_url, roster(tmp_path, seat("a@itworx.com"), name="d1.csv"), "2026-05-20")
    refresh(conn)

    assert one(conn, "SELECT MIN(date_day)::text FROM marts.dim_date")[0] == "2026-05-20"


def test_fact_seat_day_carries_the_tier_in_force_on_each_date(conn, pg_url, tmp_path):
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d1.csv"),
         "2026-05-20")
    load(pg_url, roster(tmp_path, seat("a@itworx.com", "Claude Premium", "6/1/2026"),
                        name="d2.csv"), "2026-06-20")
    refresh(conn)

    assert all_(
        conn,
        "SELECT date_day::text, seat_tier FROM marts.fact_seat_day"
        " WHERE date_day IN (DATE '2026-05-31', DATE '2026-06-01') ORDER BY date_day",
    ) == [("2026-05-31", "Standard"), ("2026-06-01", "Premium")]


# --- mart surface -----------------------------------------------------------


def test_the_seat_marts_expose_only_person_tier_organization_and_interval_dates(conn):
    columns = all_(
        conn,
        "SELECT c.relname, a.attname FROM pg_attribute a"
        " JOIN pg_class c ON a.attrelid = c.oid"
        " JOIN pg_namespace n ON c.relnamespace = n.oid"
        " WHERE n.nspname = 'marts' AND a.attnum > 0 AND NOT a.attisdropped"
        " AND c.relname IN ('dim_seat', 'dim_seat_current', 'fact_seat_day')"
        " ORDER BY c.relname, a.attnum",
    )
    assert columns == [
        ("dim_seat", "user_email"),
        ("dim_seat", "seat_tier"),
        ("dim_seat", "anthropic_org_name"),
        ("dim_seat", "valid_from"),
        ("dim_seat", "valid_to"),
        ("dim_seat", "valid_from_basis"),
        ("dim_seat_current", "user_email"),
        ("dim_seat_current", "seat_tier"),
        ("dim_seat_current", "anthropic_org_name"),
        ("dim_seat_current", "valid_from"),
        ("fact_seat_day", "date_day"),
        ("fact_seat_day", "user_email"),
        ("fact_seat_day", "seat_tier"),
        ("fact_seat_day", "anthropic_org_name"),
    ]


def test_dim_seat_current_holds_one_row_per_person_with_an_open_seat(conn, pg_url, tmp_path):
    load(
        pg_url,
        roster(
            tmp_path,
            seat("a@itworx.com", assigned="4/8/2026"),
            seat("b@itworx.com", assigned="4/9/2026"),
            name="d1.csv",
        ),
        "2026-05-20",
    )
    load(pg_url, roster(tmp_path, seat("a@itworx.com", "Claude Premium", "6/1/2026"),
                        name="d2.csv"), "2026-06-20")
    refresh(conn)

    assert all_(
        conn,
        "SELECT user_email, seat_tier, valid_from::text FROM marts.dim_seat_current"
        " ORDER BY user_email",
    ) == [("a@itworx.com", "Premium", "2026-06-01")]


def test_the_three_seat_marts_are_registered_in_the_full_refresh(conn, pg_url, tmp_path):
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d1.csv"),
         "2026-05-20")
    refresh(conn)

    logged = {row[0] for row in all_(conn, "SELECT mart FROM marts.mart_refresh_log")}
    assert set(SEAT_MARTS) <= logged


def test_the_read_login_selects_the_seat_marts_but_not_the_reference_tables(conn):
    for mart in SEAT_MARTS:
        assert one(
            conn, f"SELECT has_table_privilege('cc_otel_read', 'marts.{mart}', 'SELECT')"
        )[0], mart
    for table in ("ref.roster_drop", "ref.seat_roster_snapshot"):
        assert not one(
            conn, f"SELECT has_table_privilege('cc_otel_read', '{table}', 'SELECT')"
        )[0], table


def test_the_loader_refreshes_the_seat_marts_on_write(conn, pg_url, tmp_path):
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d1.csv"),
         "2026-05-20")

    # No marts.refresh_all() here: the loader's own targeted refresh must have landed it.
    assert one(conn, "SELECT COUNT(*) FROM marts.dim_seat_current")[0] == 1
    assert one(conn, "SELECT MIN(date_day)::text FROM marts.dim_date")[0] == "2026-04-08"


# --- data-quality findings --------------------------------------------------


def test_telemetry_after_a_close_is_flagged(conn, pg_url, tmp_path):
    load(
        pg_url,
        roster(
            tmp_path,
            seat("a@itworx.com", assigned="4/8/2026"),
            seat("b@itworx.com", assigned="4/9/2026"),
            name="d1.csv",
        ),
        "2026-05-20",
    )
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d2.csv"),
         "2026-06-20")
    ins_event(
        conn,
        event_time="2026-07-01T10:00:00Z",
        event_name="api_request",
        user_email="b@itworx.com",
    )
    refresh(conn)

    rows = finding(conn, "seat_telemetry_after_close")
    assert len(rows) == 1
    row_count, details = rows[0]
    assert row_count == 1
    assert details["user_email"] == "b@itworx.com"
    assert details["closed_on"] == "2026-06-20"
    assert details["first_activity_after_close"] == "2026-07-01"


def test_a_seat_reopening_after_one_missed_drop_is_flagged(conn, pg_url, tmp_path):
    both = (seat("a@itworx.com", assigned="4/8/2026"), seat("b@itworx.com", assigned="4/9/2026"))
    load(pg_url, roster(tmp_path, *both, name="d1.csv"), "2026-05-20")
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d2.csv"),
         "2026-06-20")
    load(pg_url, roster(tmp_path, *both, name="d3.csv"), "2026-07-20")
    refresh(conn)

    rows = finding(conn, "seat_reopened_within_cadence")
    assert len(rows) == 1
    assert rows[0][1]["user_email"] == "b@itworx.com"
    assert rows[0][1]["closed_on"] == "2026-06-20"
    assert rows[0][1]["reopened_on"] == "2026-07-20"


def test_a_continuous_seat_is_not_flagged_as_reopened(conn, pg_url, tmp_path):
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d1.csv"),
         "2026-05-20")
    load(pg_url, roster(tmp_path, seat("a@itworx.com", "Claude Premium", "6/1/2026"),
                        name="d2.csv"), "2026-06-20")
    refresh(conn)

    assert finding(conn, "seat_reopened_within_cadence") == []


def test_an_assignment_date_with_no_tier_is_flagged(conn, pg_url, tmp_path):
    load(
        pg_url,
        roster(
            tmp_path,
            seat("pending@itworx.com", tier="", assigned="4/8/2026"),
            seat("a@itworx.com", assigned="4/8/2026"),
            name="d1.csv",
        ),
        "2026-05-20",
    )
    refresh(conn)

    rows = finding(conn, "seat_assignment_without_tier")
    assert len(rows) == 1
    assert rows[0][1]["user_email"] == "pending@itworx.com"
    assert rows[0][1]["assignment_date"] == "2026-04-08"


def test_an_emitter_with_no_seat_is_flagged_against_raw_telemetry(conn, pg_url, tmp_path):
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d1.csv"),
         "2026-05-20")
    ins_event(
        conn,
        event_time="2026-07-01T10:00:00Z",
        event_name="api_request",
        user_email="personal@gmail.com",
    )
    # A null-email row buckets to '(unknown)' in dim_user; reading raw directly means the
    # finding reports the real identity and never an '(unknown)' emitter.
    ins_event(conn, event_time="2026-07-01T10:01:00Z", event_name="api_request")
    refresh(conn)

    rows = finding(conn, "seat_emitter_without_seat")
    assert len(rows) == 1
    assert rows[0][1]["user_email"] == "personal@gmail.com"
    assert rows[0][0] == 1


def test_a_seat_holder_emitting_inside_their_interval_is_not_flagged(conn, pg_url, tmp_path):
    load(pg_url, roster(tmp_path, seat("a@itworx.com", assigned="4/8/2026"), name="d1.csv"),
         "2026-05-20")
    ins_event(
        conn, event_time="2026-05-01T10:00:00Z", event_name="api_request",
        user_email="a@itworx.com",
    )
    refresh(conn)

    assert finding(conn, "seat_emitter_without_seat") == []
    assert finding(conn, "seat_telemetry_after_close") == []


def test_a_second_concurrent_subscription_is_flagged_and_does_not_multiply_seat_days(
    conn, pg_url, tmp_path
):
    load(
        pg_url,
        roster(
            tmp_path,
            "a@itworx.com,ITWorx,Claude Standard,4/8/2026,Claude Premium,5/1/2026",
            name="d1.csv",
            header=HEADER + ",subscription_2,assignment_date_2",
        ),
        "2026-05-20",
    )
    refresh(conn)

    rows = finding(conn, "seat_multi_subscription")
    assert len(rows) == 1
    assert rows[0][0] == 2
    assert rows[0][1]["user_email"] == "a@itworx.com"
    assert rows[0][1]["tiers"] == ["Standard", "Premium"]
    # The reporting grain asserts one active tier per person.
    assert one(conn, "SELECT COUNT(*) FROM marts.dim_seat_current")[0] == 1


def test_the_observation_dated_share_of_boundaries_is_reported(conn, pg_url, tmp_path):
    load(
        pg_url,
        roster(
            tmp_path,
            seat("a@itworx.com", assigned="4/8/2026"),
            seat("b@itworx.com"),
            name="d1.csv",
        ),
        "2026-05-20",
    )
    refresh(conn)

    rows = finding(conn, "seat_boundary_basis")
    assert len(rows) == 1
    row_count, details = rows[0]
    assert row_count == 1
    assert (details["source_dated"], details["observation_dated"], details["total"]) == (1, 1, 2)
    assert float(details["observation_dated_share"]) == 0.5


def test_no_seat_findings_fire_with_no_roster_loaded(conn):
    ins_event(
        conn, event_time="2026-07-01T10:00:00Z", event_name="api_request",
        user_email="a@itworx.com",
    )
    refresh(conn)

    seat_findings = {
        row[0]
        for row in all_(
            conn,
            "SELECT finding_type FROM marts.dq_finding WHERE finding_type LIKE 'seat%'",
        )
    }
    # No intervals exist, so nothing can be after a close and no boundary basis is measurable;
    # the emitter finding is the one honest signal — the roster simply is not loaded yet.
    assert seat_findings == {"seat_emitter_without_seat"}
