"""Unit tests for the roster loader's pure parse / delta / guard seams (#292)."""

from __future__ import annotations

from dataclasses import replace
from datetime import date

import pytest

from tools.roster_load import (
    RosterError,
    SeatRow,
    compute_delta,
    guard_violations,
    impossible_as_of,
    normalize_tier,
    parse_rows,
)

# IS's real header, in its real order (the file itself is operator-held: it carries
# employee PII and is never committed).
HEADER = "name,email,manager,department,cost_center,Team,subscription_1,assignment_date_1"


def csv_text(*rows: str, header: str = HEADER) -> str:
    return "\n".join((header, *rows)) + "\n"


def seat(
    email: str, tier: str | None = "Standard", *, seq: int = 1, org: str = "ITWorx"
) -> SeatRow:
    return SeatRow(
        user_email=email,
        subscription_seq=seq,
        subscription_raw=None if tier is None else f"Claude {tier}",
        seat_tier=tier,
        assignment_date=date(2026, 4, 8),
        anthropic_org_name=org,
        person_name=None,
        manager_name=None,
        department=None,
        cost_center=None,
        extra={},
    )


class TestNormalizeTier:
    @pytest.mark.parametrize(
        ("raw", "expected"),
        [
            ("Claude Standard", "Standard"),
            ("Claude Premium", "Premium"),
            ("  Claude Premium  ", "Premium"),
            ("Claude Enterprise", "Enterprise"),  # unknown tier passes through, prefix stripped
            ("Standard", "Standard"),  # already normalized
            ("", None),
            ("   ", None),
            (None, None),
        ],
    )
    def test_strips_the_claude_prefix_and_blanks_to_none(
        self, raw: str | None, expected: str | None
    ) -> None:
        assert normalize_tier(raw) == expected


class TestParseRows:
    def test_maps_every_is_column(self) -> None:
        text = csv_text(
            "Dana,dana.doe@example.com,Sam Lead,PMO,"
            "02-500-Executive COR (Gulf),ITWorx,Claude Standard,4/8/2026"
        )
        (row,) = parse_rows(text)
        assert row == SeatRow(
            user_email="dana.doe@example.com",
            subscription_seq=1,
            subscription_raw="Claude Standard",
            seat_tier="Standard",
            assignment_date=date(2026, 4, 8),
            anthropic_org_name="ITWorx",
            person_name="Dana",
            manager_name="Sam Lead",
            department="PMO",
            cost_center="02-500-Executive COR (Gulf)",
            extra={},
        )

    def test_normalizes_email_to_lowercase(self) -> None:
        text = csv_text("D,  Dana.Doe@Example.com ,,,,ITWorx,Claude Premium,6/16/2026")
        (row,) = parse_rows(text)
        assert row.user_email == "dana.doe@example.com"

    def test_captures_unmapped_headers_into_extra(self) -> None:
        text = csv_text(
            "a@itworx.com,Claude Standard,Revoked,2026-07-01",
            header="email,subscription_1,status,revocation_date",
        )
        (row,) = parse_rows(text)
        assert row.extra == {"status": "Revoked", "revocation_date": "2026-07-01"}

    def test_omits_empty_unmapped_values_from_extra(self) -> None:
        text = csv_text("a@itworx.com,Claude Standard,", header="email,subscription_1,status")
        (row,) = parse_rows(text)
        assert row.extra == {}

    def test_loads_when_every_descriptive_column_is_absent(self) -> None:
        text = csv_text(
            "a@itworx.com,ITWorx,Claude Standard,4/8/2026",
            header="email,Team,subscription_1,assignment_date_1",
        )
        (row,) = parse_rows(text)
        assert (row.person_name, row.manager_name, row.department, row.cost_center) == (
            None,
            None,
            None,
            None,
        )
        assert row.seat_tier == "Standard"

    def test_loads_a_row_with_an_assignment_date_and_no_tier(self) -> None:
        text = csv_text("A,a@itworx.com,M,Dept,CC,ITWorx,,4/8/2026")
        (row,) = parse_rows(text)
        assert row.seat_tier is None
        assert row.subscription_raw is None
        assert row.assignment_date == date(2026, 4, 8)

    def test_unpivots_a_second_subscription_into_its_own_row(self) -> None:
        text = csv_text(
            "a@itworx.com,Claude Standard,4/8/2026,Claude Premium,6/16/2026",
            header="email,subscription_1,assignment_date_1,subscription_2,assignment_date_2",
        )
        first, second = parse_rows(text)
        assert (first.subscription_seq, first.seat_tier) == (1, "Standard")
        assert (second.subscription_seq, second.seat_tier) == (2, "Premium")
        assert second.assignment_date == date(2026, 6, 16)

    def test_emits_no_row_for_an_entirely_empty_subscription_pair(self) -> None:
        text = csv_text(
            "a@itworx.com,Claude Standard,4/8/2026,,",
            header="email,subscription_1,assignment_date_1,subscription_2,assignment_date_2",
        )
        assert [row.subscription_seq for row in parse_rows(text)] == [1]

    def test_emits_one_row_when_the_file_carries_no_subscription_columns(self) -> None:
        text = csv_text("a@itworx.com,ITWorx", header="email,Team")
        (row,) = parse_rows(text)
        assert (row.subscription_seq, row.seat_tier, row.assignment_date) == (1, None, None)

    def test_reads_subscription_columns_whatever_their_casing(self) -> None:
        # Header names are matched case- and whitespace-insensitively throughout, so an IS
        # export that re-cases its headers must not silently land a blank tier and date.
        text = csv_text(
            "a@example.com,Claude Premium,6/16/2026",
            header="Email, Subscription_1 ,ASSIGNMENT_DATE_1",
        )
        (row,) = parse_rows(text)
        assert (row.seat_tier, row.assignment_date) == ("Premium", date(2026, 6, 16))

    def test_accepts_iso_assignment_dates(self) -> None:
        text = csv_text(
            "a@itworx.com,Claude Standard,2026-04-08",
            header="email,subscription_1,assignment_date_1",
        )
        (row,) = parse_rows(text)
        assert row.assignment_date == date(2026, 4, 8)

    def test_refuses_a_file_with_no_email_column(self) -> None:
        with pytest.raises(RosterError, match="email"):
            parse_rows(csv_text("Claude Standard", header="name,subscription_1"))

    def test_refuses_a_row_with_a_blank_email(self) -> None:
        with pytest.raises(RosterError, match="line 3"):
            parse_rows(
                csv_text(
                    "A,a@itworx.com,M,D,C,ITWorx,Claude Standard,4/8/2026",
                    "B,,M,D,C,ITWorx,Claude Standard,4/8/2026",
                )
            )

    def test_refuses_a_repeated_person_and_subscription(self) -> None:
        # The snapshot's primary key is (drop, person, subscription); a repeat must be a named
        # refusal, not a UniqueViolation stack trace mid-insert.
        with pytest.raises(RosterError, match="a@itworx.com"):
            parse_rows(
                csv_text(
                    "A,a@itworx.com,M,D,C,ITWorx,Claude Standard,4/8/2026",
                    "A,A@itworx.com,M,D,C,ITWorx2,Claude Premium,4/8/2026",
                )
            )

    def test_refuses_an_unparseable_assignment_date(self) -> None:
        with pytest.raises(RosterError, match="assignment_date_1"):
            parse_rows(
                csv_text(
                    "a@itworx.com,Claude Standard,08.04.2026",
                    header="email,subscription_1,assignment_date_1",
                )
            )


class TestComputeDelta:
    def test_counts_new_tier_changed_closed_and_unchanged_seats(self) -> None:
        prior = [seat("stay@itworx.com"), seat("up@itworx.com"), seat("gone@itworx.com")]
        incoming = [
            seat("stay@itworx.com"),
            seat("up@itworx.com", "Premium"),
            seat("new@itworx.com"),
        ]
        assert compute_delta(prior, incoming) == (1, 1, 1, 1)

    def test_treats_every_seat_as_new_against_a_first_drop(self) -> None:
        assert compute_delta([], [seat("a@itworx.com"), seat("b@itworx.com")]) == (2, 0, 0, 0)

    def test_keys_on_subscription_sequence_so_a_second_seat_is_new(self) -> None:
        prior = [seat("a@itworx.com")]
        incoming = [seat("a@itworx.com"), seat("a@itworx.com", "Premium", seq=2)]
        assert compute_delta(prior, incoming) == (1, 0, 0, 1)

    def test_counts_a_tier_appearing_where_there_was_none_as_a_tier_change(self) -> None:
        assert compute_delta([seat("a@itworx.com", None)], [seat("a@itworx.com")]) == (0, 1, 0, 0)


class TestImpossibleAsOf:
    def test_refuses_an_as_of_before_the_newest_assignment_date(self) -> None:
        rows = [
            seat("a@itworx.com"),
            replace(seat("b@itworx.com"), assignment_date=date(2026, 7, 20)),
        ]
        assert impossible_as_of(date(2026, 7, 19), rows) is not None

    def test_accepts_an_as_of_on_the_newest_assignment_date(self) -> None:
        assert impossible_as_of(date(2026, 4, 8), [seat("a@itworx.com")]) is None

    def test_accepts_any_as_of_when_the_file_carries_no_assignment_dates(self) -> None:
        rows = [replace(seat("a@itworx.com"), assignment_date=None)]
        assert impossible_as_of(date(2020, 1, 1), rows) is None


class TestGuardViolations:
    def test_passes_a_normal_drop(self) -> None:
        prior = [seat(f"u{n}@itworx.com") for n in range(100)]
        incoming = [seat(f"u{n}@itworx.com") for n in range(102)]
        assert guard_violations(date(2026, 7, 24), date(2026, 7, 10), prior, incoming) == []

    def test_flags_a_row_count_falling_more_than_ten_percent(self) -> None:
        prior = [seat(f"u{n}@itworx.com") for n in range(100)]
        incoming = [seat(f"u{n}@itworx.com") for n in range(89)]
        (violation,) = guard_violations(date(2026, 7, 24), date(2026, 7, 10), prior, incoming)
        assert "row count" in violation

    def test_tolerates_a_row_count_falling_exactly_ten_percent(self) -> None:
        prior = [seat(f"u{n}@itworx.com") for n in range(100)]
        incoming = [seat(f"u{n}@itworx.com") for n in range(90)]
        assert guard_violations(date(2026, 7, 24), date(2026, 7, 10), prior, incoming) == []

    def test_flags_an_organization_that_vanished(self) -> None:
        prior = [seat("a@itworx.com"), seat("b@itworx.com", org="ITWorx2")]
        incoming = [seat("a@itworx.com")]
        violations = guard_violations(date(2026, 7, 24), date(2026, 7, 10), prior, incoming)
        assert any("ITWorx2" in v for v in violations)

    def test_flags_a_tier_value_that_vanished(self) -> None:
        prior = [seat("a@itworx.com"), seat("b@itworx.com", "Premium")]
        incoming = [seat("a@itworx.com"), seat("b@itworx.com")]
        violations = guard_violations(date(2026, 7, 24), date(2026, 7, 10), prior, incoming)
        assert any("Premium" in v for v in violations)

    def test_flags_an_as_of_duplicating_the_newest_existing_drop(self) -> None:
        rows = [seat("a@itworx.com")]
        (violation,) = guard_violations(date(2026, 7, 10), date(2026, 7, 10), rows, rows)
        assert "as-of" in violation

    def test_flags_an_as_of_preceding_the_newest_existing_drop(self) -> None:
        rows = [seat("a@itworx.com")]
        (violation,) = guard_violations(date(2026, 7, 1), date(2026, 7, 10), rows, rows)
        assert "as-of" in violation

    def test_passes_a_first_drop_with_no_prior_as_of(self) -> None:
        assert guard_violations(date(2026, 7, 10), None, [], [seat("a@itworx.com")]) == []
