"""Re-check every ``kept`` classification against a recent reservoir window (#366).

``tools.sweep`` reports *unclassified* keys and redaction leaks; a key classified ``kept``
never resurfaces there however far its live distribution drifts from the evidence the
classification rested on. That is fine for keys kept on their **nature** — identity or
unbounded cardinality — and not fine for the ones kept because a measurement said so at a
point in time. This tool re-derives those measurements. **Basis drift** and **kept basis**
are the ``CONTEXT.md`` entries; the basis itself lives on ``meta.column_registry``
(``kept_basis`` / ``basis_partner``), never in a stored baseline — a number recorded today
is the exact staleness this tool exists to catch, reintroduced.

Per-basis predicates:

======================  ==========================================================
``nature``              never evaluated — cannot drift
``constant``            cardinality of **present** values == 1
``collinear``           functional dependency ``basis_partner`` -> key, **counting
                        absence as a value**
``thin``                seats carrying the key < 50% of the window's reporting seats
``redundant``           never evaluated — the claim is cross-grain, so no single
                        record can answer it; the argument lives in ``notes``
======================  ==========================================================

**The asymmetry between ``constant`` and ``collinear`` is deliberate — do not "fix" it.**
``constant`` counts present values only and ignores absence: it is a claim about what the
key *is* when it is there. ``collinear`` counts absence as a value, which is what lets one
rule cover both a value dependency (``windows`` -> ``10.0.26200``) and a presence
dependency (``wsl.version`` present iff ``os.type='linux'``): a native, non-WSL Linux seat
puts ``{2, absent}`` in the ``linux`` group and a mixed Windows build puts two versions in
the ``windows`` group, and the same check catches both.

``thin`` compares against the window's *reporting-seat population*, not a hardcoded count
(#244 flips 17 machines to prod and any literal rots that day). Because both sides of that
ratio shrink with the window, a quiet window would false-alarm — 2 seats of 4 reads 50% for
a key that reaches one seat in twenty — so ``thin`` is **not evaluated** below
``THIN_SEAT_FLOOR`` reporting seats, and the skip is always reported. ``constant`` and
``collinear`` need no such guard: they require a single counterexample, so a short window
can miss drift but never invent it.

Manual / on-demand, like the sweep, the scrub and the compaction tool — it needs blob
credentials and a multi-minute window read, so it is deliberately not in CI and not in
``spec_sync --check`` (which is definitional and needs no reservoir). Exit 1 on any drift.

    uv run python -m tools.basis_drift --days 7
    uv run python -m tools.basis_drift --since 2026-07-18 --until 2026-07-28
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from datetime import UTC, date, datetime
from typing import TYPE_CHECKING, Any, NamedTuple

import duckdb
import psycopg
from cc_otel_sink.config import load_settings

from ._payload import iter_records, read_payloads
from ._progress import Progress
from ._reservoir import configure_duckdb
from ._window import resolve_window
from .signals import ROUTES

if TYPE_CHECKING:
    from cc_otel_sink.config import Settings

THIN_SHARE = 0.5
"""Seat share at which a ``thin`` claim is contradicted — the key reaches half the fleet."""

THIN_SEAT_FLOOR = 10
"""Reporting seats a window needs before ``thin`` is evaluated at all (see module docstring)."""

EVIDENCE_CAP = 5
"""Distinct values retained per tracked set, for the violation message.

A single counterexample already settles ``constant`` and ``collinear``, so nothing is lost
by not counting past this — it only bounds memory on a key that turns out to be wide.
"""

CHECKABLE = frozenset({"constant", "collinear", "thin"})
"""Bases with a machine predicate. ``nature`` and ``redundant`` are exempt by construction."""


class Claim(NamedTuple):
    """One registry row's kept-basis claim, at the registry's own grain.

    ``signal_name`` is ``'*'`` for a claim that spans every metric/event name under its
    signal (and for resource blocks), matching ``meta.column_registry``.
    """

    signal: str
    signal_name: str
    attr_path: str
    basis: str
    partner: str | None

    def matches(self, signal: str, name: str) -> bool:
        return self.signal == signal and self.signal_name in ("*", name)


class Violation(NamedTuple):
    signal: str
    signal_name: str
    attr_path: str
    basis: str
    evidence: str


def _capped_add(seen: set[str | None], value: str | None) -> None:
    if value in seen or len(seen) < EVIDENCE_CAP:
        seen.add(value)


@dataclass
class BasisProfile:
    """Streaming accumulator for the checkable predicates.

    ``update`` is additive so a wide window streams day by day, like ``_payload.Profile``.
    Only the claims that have a predicate are tracked; a ``collinear`` claim's partner
    value is read off the record being observed, so co-occurrence needs no join and no
    second pass.
    """

    claims: list[Claim]
    values: dict[Claim, set[str | None]] = field(default_factory=dict)
    key_seats: dict[Claim, set[str]] = field(default_factory=dict)
    dependency: dict[Claim, dict[str | None, set[str | None]]] = field(default_factory=dict)
    seats: set[str] = field(default_factory=set)
    records: int = 0

    def __post_init__(self) -> None:
        self.checkable = [c for c in self.claims if c.basis in CHECKABLE]

    def update(self, payloads: list[dict[str, Any]]) -> None:
        for payload in payloads:
            for signal, name, attrs in iter_records(payload):
                self.records += 1
                seat = attrs.get("user.email", "").strip().lower()
                if seat:
                    self.seats.add(seat)
                for claim in self.checkable:
                    if not claim.matches(signal, name):
                        continue
                    value = attrs.get(claim.attr_path)
                    if claim.basis == "constant":
                        if value is not None:
                            _capped_add(self.values.setdefault(claim, set()), value)
                    elif claim.basis == "collinear":
                        assert claim.partner is not None  # invariant 11 in column_spec
                        group = self.dependency.setdefault(claim, {}).setdefault(
                            attrs.get(claim.partner), set()
                        )
                        _capped_add(group, value)
                    elif value is not None and seat:
                        self.key_seats.setdefault(claim, set()).add(seat)


@dataclass
class Report:
    violations: list[Violation]
    reporting_seats: int
    records: int
    checked: int
    thin_evaluated: bool
    thin_claims: int
    exempt: dict[str, int]


def _show(value: str | None) -> str:
    return "(absent)" if value is None else repr(value)


def _joined(values: set[str | None]) -> str:
    return ", ".join(_show(v) for v in sorted(values, key=lambda v: (v is None, v or "")))


def evaluate(profile: BasisProfile) -> Report:
    """Run each claim's predicate over what the window actually carried.

    A claim whose key never appeared is clean by construction — ``constant`` sees zero
    values, ``collinear`` zero groups, ``thin`` zero seats. Absence is not evidence of
    drift, so an unobserved key is not a violation; the header's counts are what tell a
    reader how much the window actually covered.
    """
    reporting_seats = len(profile.seats)
    thin_evaluated = reporting_seats >= THIN_SEAT_FLOOR
    violations: list[Violation] = []
    exempt: dict[str, int] = {}
    checked = 0

    for claim in profile.claims:
        if claim.basis not in CHECKABLE:
            exempt[claim.basis] = exempt.get(claim.basis, 0) + 1
            continue
        if claim.basis == "thin" and not thin_evaluated:
            continue
        checked += 1
        evidence: str | None = None

        if claim.basis == "constant":
            values = profile.values.get(claim, set())
            if len(values) > 1:
                evidence = f"{len(values)} distinct values present: {_joined(values)}"

        elif claim.basis == "collinear":
            split = {
                partner: group
                for partner, group in profile.dependency.get(claim, {}).items()
                if len(group) > 1
            }
            if split:
                detail = "; ".join(
                    f"{_show(partner)} -> {{{_joined(group)}}}"
                    for partner, group in sorted(
                        split.items(), key=lambda kv: (kv[0] is None, kv[0] or "")
                    )
                )
                evidence = f"partner {claim.partner!r} no longer determines it: {detail}"

        else:
            carrying = len(profile.key_seats.get(claim, set()))
            if reporting_seats and carrying / reporting_seats >= THIN_SHARE:
                pct = round(100 * carrying / reporting_seats)
                evidence = (
                    f"reaches {carrying} of {reporting_seats} reporting seats ({pct}%), "
                    f"at or above the {round(100 * THIN_SHARE)}% share"
                )

        if evidence is not None:
            violations.append(
                Violation(claim.signal, claim.signal_name, claim.attr_path, claim.basis, evidence)
            )

    return Report(
        violations=violations,
        reporting_seats=reporting_seats,
        records=profile.records,
        checked=checked,
        thin_evaluated=thin_evaluated,
        thin_claims=sum(1 for c in profile.claims if c.basis == "thin"),
        exempt=exempt,
    )


def format_report(report: Report, days: list[date]) -> str:
    window = f"{days[0]:%Y-%m-%d}..{days[-1]:%Y-%m-%d}" if days else "(no window)"
    exempt = ", ".join(f"{n} {basis}" for basis, n in sorted(report.exempt.items()))
    lines = [
        f"Basis drift: window={window} ({report.records:,} records, "
        f"{report.reporting_seats} reporting seats)",
        f"  {report.checked} claims checked; {exempt or 'none'} exempt by construction",
        "",
    ]

    if not report.thin_evaluated and report.thin_claims:
        lines += [
            f"thin NOT EVALUATED — {report.thin_claims} claim(s) skipped: the window has "
            f"{report.reporting_seats} reporting seats, and the predicate needs at least "
            f"{THIN_SEAT_FLOOR}.",
            "  Both sides of the seat share shrink with the window, so a quieter one reports "
            "drift that a fuller window would not. Widen the window to check these.",
            "",
        ]

    lines.append(f"Basis drift ({len(report.violations)}):")
    if report.violations:
        for v in report.violations:
            lines.append(f"  {v.signal:<9} {v.signal_name:<32} {v.attr_path}  [{v.basis}]")
            lines.append(f"      {v.evidence}")
    else:
        lines.append("  (none)")
    return "\n".join(lines)


def load_claims(conn: psycopg.Connection) -> list[Claim]:
    """Every ``kept`` row's basis, off the deployed registry."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT signal, signal_name, attr_path, kept_basis, basis_partner "
            "FROM meta.column_registry WHERE status = 'kept' AND kept_basis IS NOT NULL "
            "ORDER BY signal, signal_name, attr_path"
        )
        return [Claim(*row) for row in cur.fetchall()]


def _profile_window(profile: BasisProfile, settings: Settings, days: list[date]) -> None:
    """Stream the window day by day into ``profile``, preferring the compacted reservoir."""
    con = duckdb.connect()
    progress = Progress("basis-drift days", total=len(days))
    try:
        configure_duckdb(con, settings)
        for day in days:
            try:
                payloads = read_payloads(
                    con,
                    settings.blob_container,
                    ROUTES,
                    [day],
                    settings.blob_compacted_container,
                )
            except duckdb.IOException:
                # configure_duckdb pins one prefetched OAuth token and a multi-day read
                # outlives it (InvalidAuthenticationInfo partway through the window).
                # Re-register once and retry; a second failure is real and propagates.
                configure_duckdb(con, settings)
                payloads = read_payloads(
                    con,
                    settings.blob_container,
                    ROUTES,
                    [day],
                    settings.blob_compacted_container,
                )
            profile.update(payloads)
            progress.tick()
    finally:
        progress.done()
        con.close()


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument(
        "--days", type=int, default=7, help="window = last N days ending today (UTC); default 7"
    )
    p.add_argument(
        "--since", type=date.fromisoformat, help="window start (YYYY-MM-DD); overrides --days"
    )
    p.add_argument(
        "--until", type=date.fromisoformat, help="window end (YYYY-MM-DD); defaults to today (UTC)"
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    days = resolve_window(args.days, args.since, args.until, datetime.now(UTC).date())
    settings = load_settings()

    with psycopg.connect(settings.database_url) as conn:
        claims = load_claims(conn)

    profile = BasisProfile(claims)
    _profile_window(profile, settings, days)
    report = evaluate(profile)
    print(format_report(report, days))
    return 1 if report.violations else 0


if __name__ == "__main__":
    sys.exit(main())
