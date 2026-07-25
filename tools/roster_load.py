"""Ingest an IS roster drop into ``ref`` as an immutable dated snapshot (#292, parent #290).

IS emails a roster CSV roughly every two weeks — a manual, therefore irregular, process. This
lands one such file: a row in ``ref.roster_drop`` (as-of date, filename, SHA-256, row count,
ingested-at/-by, notes) plus one immutable ``ref.seat_roster_snapshot`` observation per person
per subscription. Seat history is **derived** from the accumulated drops (#293), never merged
into a dimension here, so a late-arriving drop needs no repair.

Every column IS sends lands verbatim and any unmapped header is captured into ``extra``, so a
new IS column (the status / revocation date requested in #291) is retained from the moment it
first appears. No copy of the file is kept — the snapshot plus ``extra`` is the archive, a
deliberate exception to the blob-reservoir convention (ADR-0009).

Destructive (writes HR data); dry-run by default. Pass ``--execute`` to write. The dry run
prints the resolved target host and database **first**: the ambient ``DATABASE_URL`` points at
the retired POC server, so the most natural invocation would otherwise report success against a
decommissioned database.

Refusals that no flag overrides: byte-identical content already ingested, and an as-of date
earlier than the newest assignment date in the file (provably impossible). Refusals that
``--force`` overrides: an as-of duplicating or preceding the newest existing drop, and the three
whole-file-truncation guards (row count down more than 10%, an organization gone, a tier gone).

    uv run python -m tools.roster_load --file claude_users.csv --as-of 2026-07-24
    uv run python -m tools.roster_load --file claude_users.csv --as-of 2026-07-24 --execute
"""

from __future__ import annotations

import argparse
import csv
import getpass
import hashlib
import io
import re
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from typing import NamedTuple

import psycopg
from cc_otel_sink.config import load_settings
from psycopg.conninfo import conninfo_to_dict
from psycopg.types.json import Jsonb

# IS header (lowercased) -> snapshot column. The roster's descriptive columns are tolerated,
# never required, never validated: the HR view is the authoritative source for display name,
# department and manager, and the roster's copies are known to be less accurate. They are kept
# for history only, which is why a future export dropping them is not an outage.
_COLUMNS = {
    "email": "user_email",
    "name": "person_name",
    "manager": "manager_name",
    "department": "department",
    "cost_center": "cost_center",
    # Not "team": it is the Anthropic organization boundary (ITWorx -> f6584968-…,
    # ITWorx2 -> 528f9b81-…), mapping to telemetry's organization_id. Calling it a team
    # guarantees someone eventually joins it to a department.
    "team": "anthropic_org_name",
}

_SUBSCRIPTION_RE = re.compile(r"^subscription_(\d+)$")
_ASSIGNMENT_RE = re.compile(r"^assignment_date_(\d+)$")

_DATE_FORMATS = ("%Y-%m-%d", "%m/%d/%Y")

# Whole-file truncation guard: a partial export must not silently revoke a population.
_MAX_SHRINK = 0.10


class RosterError(Exception):
    """The file cannot be parsed into snapshot rows — a load failure, not a finding."""


@dataclass(frozen=True)
class SeatRow:
    """One immutable observation at assignment grain: a person's one subscription."""

    user_email: str
    subscription_seq: int
    subscription_raw: str | None
    seat_tier: str | None
    assignment_date: date | None
    anthropic_org_name: str | None
    person_name: str | None
    manager_name: str | None
    department: str | None
    cost_center: str | None
    extra: dict[str, str]


class Delta(NamedTuple):
    """The drop's effect on the prior drop's seats, at assignment grain."""

    new_seats: int
    tier_changes: int
    closures: int
    unchanged: int


def normalize_tier(raw: str | None) -> str | None:
    """Normalize IS's subscription value to the semantic model's tier vocabulary.

    ``Claude Standard`` -> ``Standard``. An unrecognized tier keeps its own name rather than
    being coerced or dropped; blank is ``None`` (a real pending-provisioning state — one such
    row exists in the first drop, and #291 asks IS whether it is intentional).
    """
    text = (raw or "").strip()
    if not text:
        return None
    return text.removeprefix("Claude ").strip()


def _parse_date(value: str, column: str) -> date | None:
    text = value.strip()
    if not text:
        return None
    for fmt in _DATE_FORMATS:
        try:
            return datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    raise RosterError(f"{column}: cannot parse date {text!r} (expected M/D/YYYY or YYYY-MM-DD)")


def _sequences(headers: Sequence[str]) -> list[int]:
    """Subscription sequence numbers present in the header, ascending.

    IS's numerically suffixed ``subscription_1`` / ``assignment_date_1`` signal their export
    tool can emit a second subscription per person; unpivoting them here keeps a second
    subscription a data event rather than a migration.
    """
    seqs = set()
    for header in headers:
        for pattern in (_SUBSCRIPTION_RE, _ASSIGNMENT_RE):
            match = pattern.match(header)
            if match:
                seqs.add(int(match.group(1)))
    return sorted(seqs)


def parse_rows(text: str) -> list[SeatRow]:
    """Parse a roster CSV into snapshot rows, one per person per subscription.

    Email is the only structurally required field — it is the key every consumer joins on, so
    a blank one is a load failure. Everything else is tolerated.
    """
    reader = csv.DictReader(io.StringIO(text))
    headers = list(reader.fieldnames or [])
    lowered = {header: header.strip().lower() for header in headers}
    if "email" not in lowered.values():
        raise RosterError(f"no `email` column in header: {', '.join(headers) or '(empty)'}")

    # Normalized key -> the header as written, so every lookup below is case- and
    # whitespace-insensitive: a re-cased IS export must not land a blank tier and date.
    by_key = {key: header for header, key in lowered.items()}
    seqs = _sequences(list(lowered.values()))
    unmapped = [
        header
        for header, key in lowered.items()
        if key not in _COLUMNS and not _SUBSCRIPTION_RE.match(key) and not _ASSIGNMENT_RE.match(key)
    ]

    rows: list[SeatRow] = []
    for line, record in enumerate(reader, start=2):
        mapped = {
            column: (record.get(header) or "").strip()
            for header, key in lowered.items()
            if (column := _COLUMNS.get(key)) is not None
        }
        if not mapped.get("user_email"):
            raise RosterError(f"line {line}: blank email — the roster's only required column")
        extra = {
            header: value for header in unmapped if (value := (record.get(header) or "").strip())
        }
        for seq in seqs or [1]:
            subscription = (record.get(by_key.get(f"subscription_{seq}", "")) or "").strip()
            assigned = _parse_date(
                record.get(by_key.get(f"assignment_date_{seq}", "")) or "",
                f"assignment_date_{seq}",
            )
            if seq != 1 and not subscription and assigned is None:
                continue
            rows.append(
                SeatRow(
                    user_email=mapped["user_email"].lower(),
                    subscription_seq=seq,
                    subscription_raw=subscription or None,
                    seat_tier=normalize_tier(subscription),
                    assignment_date=assigned,
                    anthropic_org_name=mapped.get("anthropic_org_name") or None,
                    person_name=mapped.get("person_name") or None,
                    manager_name=mapped.get("manager_name") or None,
                    department=mapped.get("department") or None,
                    cost_center=mapped.get("cost_center") or None,
                    extra=extra,
                )
            )
    seen: set[tuple[str, int]] = set()
    for row in rows:
        key = (row.user_email, row.subscription_seq)
        if key in seen:
            raise RosterError(
                f"{row.user_email} appears twice with subscription {row.subscription_seq} — "
                "the snapshot is keyed by drop, person and subscription"
            )
        seen.add(key)
    return rows


def compute_delta(prior: Sequence[SeatRow], incoming: Sequence[SeatRow]) -> Delta:
    """Diff the incoming drop against the newest existing one, keyed person + subscription.

    Closures are absences: IS sends a current-state snapshot with no status column, so a seat
    that stops appearing is a revocation. This count is the human checkpoint for that inference
    — the guards only catch truncation, not a plausible-looking export missing a few people.
    """
    before = {(row.user_email, row.subscription_seq): row.seat_tier for row in prior}
    after = {(row.user_email, row.subscription_seq): row.seat_tier for row in incoming}
    return Delta(
        new_seats=sum(1 for key in after if key not in before),
        tier_changes=sum(1 for key, tier in after.items() if key in before and before[key] != tier),
        closures=sum(1 for key in before if key not in after),
        unchanged=sum(1 for key, tier in after.items() if key in before and before[key] == tier),
    )


def impossible_as_of(as_of: date, rows: Sequence[SeatRow]) -> str | None:
    """Return why the as-of date is provably impossible, or ``None``.

    A seat cannot be assigned after the export that reports it, so an as-of earlier than the
    newest assignment date in the file is a typo. No flag overrides this one.
    """
    assigned = [row.assignment_date for row in rows if row.assignment_date is not None]
    newest = max(assigned, default=None)
    if newest is not None and as_of < newest:
        return f"as-of {as_of} precedes the newest assignment date in the file ({newest})"
    return None


def guard_violations(
    as_of: date,
    prior_as_of: date | None,
    prior: Sequence[SeatRow],
    incoming: Sequence[SeatRow],
) -> list[str]:
    """Return the ``--force``-overridable objections to this drop.

    Ordering keeps derived history sane; the other three defend against whole-file truncation,
    the failure mode that revocation-by-absence actually exposes. A confirmation window (revoke
    only after two absences) was rejected — it taxes every legitimate revocation, and deleting a
    bad drop already heals derived history (ADR-0009).
    """
    violations: list[str] = []
    if prior_as_of is not None and as_of <= prior_as_of:
        violations.append(
            f"as-of {as_of} duplicates or precedes the newest existing drop ({prior_as_of})"
        )
    if prior and len(incoming) < len(prior) * (1 - _MAX_SHRINK):
        violations.append(
            f"row count {len(incoming)} falls more than {_MAX_SHRINK:.0%} "
            f"against the prior drop ({len(prior)}) — possible truncated export"
        )

    def vanished(value: Callable[[SeatRow], str | None]) -> list[str]:
        before = {v for row in prior if (v := value(row))}
        after = {v for row in incoming if (v := value(row))}
        return sorted(before - after)

    violations.extend(
        f"organization {name!r} present in the prior drop is absent from this one"
        for name in vanished(lambda row: row.anthropic_org_name)
    )
    violations.extend(
        f"tier {tier!r} present in the prior drop is absent from this one"
        for tier in vanished(lambda row: row.seat_tier)
    )
    return violations


def _target_label(database_url: str) -> str:
    """The host + database the write would land in — printed before anything else."""
    info = conninfo_to_dict(database_url)
    return f"host={info.get('host', '(unset)')} database={info.get('dbname', '(unset)')}"


def _drop_by_hash(conn: psycopg.Connection, digest: str) -> tuple[int, date] | None:
    row = conn.execute(
        "SELECT drop_id, as_of_date FROM ref.roster_drop WHERE file_sha256 = %s", (digest,)
    ).fetchone()
    return (row[0], row[1]) if row else None


def _newest_drop(conn: psycopg.Connection) -> tuple[date | None, list[SeatRow]]:
    """The newest existing drop's as-of date and its snapshot rows (the delta baseline)."""
    row = conn.execute(
        "SELECT drop_id, as_of_date FROM ref.roster_drop ORDER BY as_of_date DESC, drop_id DESC"
        " LIMIT 1"
    ).fetchone()
    if row is None:
        return None, []
    drop_id, as_of = row
    snapshot = conn.execute(
        "SELECT user_email, subscription_seq, subscription_raw, seat_tier, assignment_date,"
        " anthropic_org_name, person_name, manager_name, department, cost_center, extra"
        " FROM ref.seat_roster_snapshot WHERE drop_id = %s",
        (drop_id,),
    ).fetchall()
    return as_of, [SeatRow(*record) for record in snapshot]


def _insert_drop(
    conn: psycopg.Connection,
    as_of: date,
    filename: str,
    digest: str,
    rows: Sequence[SeatRow],
    ingested_by: str,
    notes: str | None,
) -> int:
    """Write the registry row and its snapshot rows in one transaction. ``row_count`` is the
    snapshot row count — assignment grain, the same number the guards compare."""
    with conn.transaction():
        result = conn.execute(
            "INSERT INTO ref.roster_drop"
            " (as_of_date, source_filename, file_sha256, row_count, ingested_by, notes)"
            " VALUES (%s, %s, %s, %s, %s, %s) RETURNING drop_id",
            (as_of, filename, digest, len(rows), ingested_by, notes),
        ).fetchone()
        assert result is not None  # noqa: S101 — RETURNING on a single-row INSERT
        drop_id = int(result[0])
        with conn.cursor() as cur:
            cur.executemany(
                "INSERT INTO ref.seat_roster_snapshot"
                " (drop_id, user_email, subscription_seq, subscription_raw, seat_tier,"
                "  assignment_date, anthropic_org_name, person_name, manager_name, department,"
                "  cost_center, extra)"
                " VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
                [
                    (
                        drop_id,
                        row.user_email,
                        row.subscription_seq,
                        row.subscription_raw,
                        row.seat_tier,
                        row.assignment_date,
                        row.anthropic_org_name,
                        row.person_name,
                        row.manager_name,
                        row.department,
                        row.cost_center,
                        Jsonb(row.extra),
                    )
                    for row in rows
                ],
            )
    return drop_id


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--file", required=True, type=Path, help="roster CSV as received from IS")
    p.add_argument(
        "--as-of",
        required=True,
        type=date.fromisoformat,
        help="the drop's as-of date (YYYY-MM-DD); the file carries no export timestamp",
    )
    p.add_argument("--notes", help="free-text note recorded on the drop")
    p.add_argument("--database-url", help="target DB; defaults to $DATABASE_URL")
    p.add_argument(
        "--force", action="store_true", help="override the as-of ordering and truncation guards"
    )
    p.add_argument("--execute", action="store_true", help="write the drop (default: dry-run)")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    database_url = args.database_url or load_settings().database_url
    if not database_url:
        print("No target database: pass --database-url or set DATABASE_URL", file=sys.stderr)
        return 2
    # Before anything else, including reading the file: the operator's first line of defense
    # against loading HR data into the retired POC server.
    print(f"Target: {_target_label(database_url)}")

    try:
        content = args.file.read_bytes()
        rows = parse_rows(content.decode("utf-8-sig"))
    except (OSError, RosterError) as err:
        print(f"Refused: {err}", file=sys.stderr)
        return 1
    digest = hashlib.sha256(content).hexdigest()
    print(f"File: {args.file.name} sha256={digest[:12]}... rows={len(rows)} as-of={args.as_of}")

    with psycopg.connect(database_url) as conn:
        existing = _drop_by_hash(conn, digest)
        if existing is not None:
            drop_id, existing_as_of = existing
            print(
                f"Refused: byte-identical content already ingested as drop {drop_id} "
                f"(as-of {existing_as_of}) — nothing written",
                file=sys.stderr,
            )
            return 1

        blocker = impossible_as_of(args.as_of, rows)
        if blocker is not None:
            print(f"Refused: {blocker} — nothing written", file=sys.stderr)
            return 1

        prior_as_of, prior = _newest_drop(conn)
        delta = compute_delta(prior, rows)
        baseline = f"prior drop as-of {prior_as_of}" if prior_as_of else "no prior drop"
        print(
            f"Delta vs {baseline}: {delta.new_seats} new, {delta.tier_changes} tier changes, "
            f"{delta.closures} closures, {delta.unchanged} unchanged"
        )
        blank_tiers = sum(1 for row in rows if row.seat_tier is None)
        if blank_tiers:
            print(f"Data quality: {blank_tiers} row(s) with no tier — loaded, not rejected")

        violations = guard_violations(args.as_of, prior_as_of, prior, rows)
        for violation in violations:
            print(f"Guard: {violation}")
        if violations and not args.force:
            print(
                f"Refused: {len(violations)} guard(s) tripped — re-run with --force to accept",
                file=sys.stderr,
            )
            return 1
        if violations:
            print("Guards overridden by --force")

        if not args.execute:
            print("Dry-run — nothing written; pass --execute to load")
            return 0

        drop_id = _insert_drop(
            conn, args.as_of, args.file.name, digest, rows, getpass.getuser(), args.notes
        )
        print(f"Loaded drop {drop_id}: {len(rows)} snapshot rows at as-of {args.as_of}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
