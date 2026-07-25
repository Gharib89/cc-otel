"""End-to-end proof for the roster loader, driven as a CLI against throwaway Postgres (#292).

The real IS file is operator-held — it carries employee PII and is never committed — so these
fixtures reproduce its header and shape, and the real 184-row load is verified by hand.
"""

from __future__ import annotations

from pathlib import Path

import psycopg
import pytest

from tools.roster_load import main

HEADER = "name,email,manager,department,cost_center,Team,subscription_1,assignment_date_1"
SHORT_HEADER = "email,Team,subscription_1,assignment_date_1"  # every descriptive column absent


def roster(tmp_path: Path, *rows: str, name: str = "claude_users.csv", header: str = HEADER) -> Path:
    path = tmp_path / name
    path.write_text("\n".join((header, *rows)) + "\n", encoding="utf-8")
    return path


def seats(
    count: int, *, tier: str = "Claude Standard", org: str = "ITWorx", start: int = 0
) -> list[str]:
    return [
        f"User {n},u{n}@itworx.com,Mgr,Dept,CC,{org},{tier},4/8/2026"
        for n in range(start, start + count)
    ]


def run(pg_url: str, path: Path, as_of: str, *extra: str) -> int:
    return main(["--file", str(path), "--as-of", as_of, "--database-url", pg_url, *extra])


def load(pg_url: str, path: Path, as_of: str, *extra: str) -> None:
    assert run(pg_url, path, as_of, "--execute", *extra) == 0


def counts(conn: psycopg.Connection) -> tuple[int, int]:
    drops = conn.execute("SELECT count(*) FROM ref.roster_drop").fetchone()
    snapshots = conn.execute("SELECT count(*) FROM ref.seat_roster_snapshot").fetchone()
    assert drops is not None and snapshots is not None
    return drops[0], snapshots[0]


def test_dry_run_prints_the_target_first_and_writes_nothing(
    conn: psycopg.Connection, pg_url: str, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = roster(tmp_path, *seats(3))

    assert run(pg_url, path, "2026-07-24") == 0

    out = capsys.readouterr().out.splitlines()
    assert out[0].startswith("Target: host=")
    assert "database=" in out[0]
    assert "Dry-run" in out[-1]
    assert counts(conn) == (0, 0)


def test_execute_records_the_drop_and_its_snapshot_rows(
    conn: psycopg.Connection, pg_url: str, tmp_path: Path
) -> None:
    path = roster(
        tmp_path,
        "Nermine,Nermine.Ghonima@itworx.com,Asser Ezzo,PMO,02-500,ITWorx,Claude Standard,4/8/2026",
        "Ahmed,ahmed.gharib@itworx.com,Boss,Eng,03-100,ITWorx2,Claude Premium,6/16/2026",
    )

    load(pg_url, path, "2026-07-24", "--notes", "second July drop", "--ingested-by", "tester")

    drop = conn.execute(
        "SELECT as_of_date, source_filename, length(file_sha256), row_count, ingested_by, notes"
        " FROM ref.roster_drop"
    ).fetchone()
    assert drop is not None
    as_of, filename, digest_len, row_count, ingested_by, notes = drop
    assert (str(as_of), filename, digest_len) == ("2026-07-24", "claude_users.csv", 64)
    assert (row_count, ingested_by, notes) == (2, "tester", "second July drop")

    rows = conn.execute(
        "SELECT user_email, subscription_seq, subscription_raw, seat_tier, assignment_date,"
        " anthropic_org_name, person_name, manager_name, department, cost_center, extra"
        " FROM ref.seat_roster_snapshot ORDER BY user_email"
    ).fetchall()
    assert rows[0][:6] == (
        "ahmed.gharib@itworx.com",
        1,
        "Claude Premium",
        "Premium",
        rows[0][4],
        "ITWorx2",
    )
    assert str(rows[0][4]) == "2026-06-16"
    assert rows[1][0] == "nermine.ghonima@itworx.com"  # email normalized to lowercase
    assert rows[1][3] == "Standard"  # tier normalized off "Claude Standard"
    assert rows[1][6:10] == ("Nermine", "Asser Ezzo", "PMO", "02-500")
    assert rows[1][10] == {}


def test_an_unmapped_header_lands_in_extra(
    conn: psycopg.Connection, pg_url: str, tmp_path: Path
) -> None:
    path = roster(
        tmp_path,
        "a@itworx.com,ITWorx,Claude Standard,4/8/2026,Revoked,2026-07-20",
        header="email,Team,subscription_1,assignment_date_1,status,revocation_date",
    )

    load(pg_url, path, "2026-07-24")

    row = conn.execute("SELECT extra FROM ref.seat_roster_snapshot").fetchone()
    assert row is not None
    assert row[0] == {"status": "Revoked", "revocation_date": "2026-07-20"}


def test_reingesting_byte_identical_content_is_refused(
    conn: psycopg.Connection, pg_url: str, tmp_path: Path
) -> None:
    path = roster(tmp_path, *seats(3))
    load(pg_url, path, "2026-07-24")

    # A forwarded email re-saved under another name, on a later as-of, with --force: still the
    # same bytes, so still refused — the hash is the idempotency key.
    resent = roster(tmp_path, *seats(3), name="claude_users (1).csv")
    assert run(pg_url, resent, "2026-08-07", "--execute", "--force") == 1
    assert counts(conn) == (1, 3)


def test_an_as_of_before_the_newest_assignment_date_is_refused_even_with_force(
    conn: psycopg.Connection, pg_url: str, tmp_path: Path
) -> None:
    path = roster(tmp_path, "a@itworx.com,ITWorx,Claude Standard,7/20/2026", header=SHORT_HEADER)

    assert run(pg_url, path, "2026-07-19", "--execute", "--force") == 1
    assert counts(conn) == (0, 0)


def test_an_as_of_duplicating_an_existing_drop_needs_force(
    conn: psycopg.Connection, pg_url: str, tmp_path: Path
) -> None:
    load(pg_url, roster(tmp_path, *seats(3), name="first.csv"), "2026-07-24")
    corrected = roster(tmp_path, *seats(4), name="corrected.csv")

    assert run(pg_url, corrected, "2026-07-24", "--execute") == 1
    assert counts(conn) == (1, 3)

    load(pg_url, corrected, "2026-07-24", "--force")
    assert counts(conn) == (2, 7)


def test_a_truncated_looking_drop_needs_force(
    conn: psycopg.Connection, pg_url: str, tmp_path: Path
) -> None:
    load(pg_url, roster(tmp_path, *seats(100), name="full.csv"), "2026-07-24")
    truncated = roster(tmp_path, *seats(89), name="truncated.csv")

    assert run(pg_url, truncated, "2026-08-07", "--execute") == 1
    assert counts(conn) == (1, 100)

    load(pg_url, truncated, "2026-08-07", "--force")
    assert counts(conn) == (2, 189)


def test_a_drop_missing_an_organization_needs_force(
    conn: psycopg.Connection, pg_url: str, tmp_path: Path
) -> None:
    load(
        pg_url,
        roster(tmp_path, *seats(50), *seats(50, org="ITWorx2", start=50), name="both.csv"),
        "2026-07-24",
    )
    one_org = roster(tmp_path, *seats(100), name="one-org.csv")

    assert run(pg_url, one_org, "2026-08-07", "--execute") == 1
    assert counts(conn) == (1, 100)


def test_a_drop_losing_a_tier_value_needs_force(
    conn: psycopg.Connection, pg_url: str, tmp_path: Path
) -> None:
    load(
        pg_url,
        roster(
            tmp_path,
            *seats(50),
            *seats(50, tier="Claude Premium", start=50),
            name="two-tier.csv",
        ),
        "2026-07-24",
    )
    one_tier = roster(tmp_path, *seats(100), name="one-tier.csv")

    assert run(pg_url, one_tier, "2026-08-07", "--execute") == 1
    assert counts(conn) == (1, 100)


def test_a_csv_missing_every_descriptive_column_loads(
    conn: psycopg.Connection, pg_url: str, tmp_path: Path
) -> None:
    path = roster(tmp_path, "a@itworx.com,ITWorx,Claude Standard,4/8/2026", header=SHORT_HEADER)

    load(pg_url, path, "2026-07-24")

    row = conn.execute(
        "SELECT person_name, manager_name, department, cost_center, seat_tier"
        " FROM ref.seat_roster_snapshot"
    ).fetchone()
    assert row == (None, None, None, None, "Standard")


def test_a_row_with_an_assignment_date_and_no_tier_loads(
    conn: psycopg.Connection, pg_url: str, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = roster(
        tmp_path,
        "Pending,pending@itworx.com,Mgr,Dept,CC,ITWorx,,4/8/2026",
        "Ok,ok@itworx.com,Mgr,Dept,CC,ITWorx,Claude Standard,4/8/2026",
    )

    load(pg_url, path, "2026-07-24")

    assert "1 row(s) with no tier" in capsys.readouterr().out
    row = conn.execute(
        "SELECT seat_tier, assignment_date FROM ref.seat_roster_snapshot"
        " WHERE user_email = 'pending@itworx.com'"
    ).fetchone()
    assert row is not None
    assert row[0] is None
    assert str(row[1]) == "2026-04-08"


def test_the_dry_run_reports_the_delta_against_the_prior_drop(
    conn: psycopg.Connection, pg_url: str, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    load(pg_url, roster(tmp_path, *seats(3), name="first.csv"), "2026-07-24")
    capsys.readouterr()
    later = roster(
        tmp_path,
        "User 0,u0@itworx.com,Mgr,Dept,CC,ITWorx,Claude Standard,4/8/2026",  # unchanged
        "User 1,u1@itworx.com,Mgr,Dept,CC,ITWorx,Claude Premium,4/8/2026",  # tier change
        "User 9,u9@itworx.com,Mgr,Dept,CC,ITWorx,Claude Standard,4/8/2026",  # new
        name="later.csv",  # u2 absent -> closure
    )

    assert run(pg_url, later, "2026-08-07") == 0

    assert (
        "Delta vs prior drop as-of 2026-07-24: 1 new, 1 tier changes, 1 closures, 1 unchanged"
        in capsys.readouterr().out
    )
    assert counts(conn) == (1, 3)
