"""Unit coverage for the basis-drift predicates (#366) — synthetic payloads, no reservoir."""

from __future__ import annotations

from tools.basis_drift import (
    THIN_SEAT_FLOOR,
    THIN_SHARE,
    BasisProfile,
    Claim,
    evaluate,
    format_report,
)


def _resource(seat: str, attrs: dict[str, str]) -> dict:
    """One OTLP metrics payload whose resource block carries ``attrs``."""
    pairs = [{"key": "user.email", "value": {"stringValue": seat}}]
    pairs += [{"key": k, "value": {"stringValue": v}} for k, v in attrs.items()]
    return {"resourceMetrics": [{"resource": {"attributes": pairs}, "scopeMetrics": []}]}


def _event(name: str, seat: str, attrs: dict[str, str]) -> dict:
    """One OTLP logs payload with a single log record under event ``name``."""
    pairs = [
        {"key": "event.name", "value": {"stringValue": name}},
        {"key": "user.email", "value": {"stringValue": seat}},
    ]
    pairs += [{"key": k, "value": {"stringValue": v}} for k, v in attrs.items()]
    return {
        "resourceLogs": [
            {
                "resource": {"attributes": []},
                "scopeLogs": [{"logRecords": [{"attributes": pairs}]}],
            }
        ]
    }


def _run(claims: list[Claim], payloads: list[dict]) -> tuple[list, bool, int]:
    profile = BasisProfile(claims)
    profile.update(payloads)
    report = evaluate(profile)
    return report.violations, report.thin_evaluated, report.reporting_seats


def _seats(n: int) -> list[str]:
    return [f"dev{i}@itworx.com" for i in range(n)]


# --- constant -----------------------------------------------------------------

CONSTANT = Claim("events", "*", "safe_mode", "constant", None)


def test_constant_clean_when_one_value() -> None:
    payloads = [_event("auth", s, {"safe_mode": "false"}) for s in _seats(12)]
    violations, _, _ = _run([CONSTANT], payloads)
    assert violations == []


def test_constant_violated_by_a_second_value() -> None:
    payloads = [_event("auth", s, {"safe_mode": "false"}) for s in _seats(11)]
    payloads.append(_event("auth", "new@itworx.com", {"safe_mode": "true"}))
    violations, _, _ = _run([CONSTANT], payloads)
    assert len(violations) == 1
    assert violations[0].attr_path == "safe_mode"
    assert violations[0].basis == "constant"
    assert "false" in violations[0].evidence and "true" in violations[0].evidence


def test_constant_ignores_absence() -> None:
    # The asymmetry with `collinear`: a constant claim is about the values the key takes
    # when present, so records without the key are not a second "value".
    payloads = [_event("auth", s, {"safe_mode": "false"}) for s in _seats(6)]
    payloads += [_event("auth", s, {}) for s in _seats(6)]
    violations, _, _ = _run([CONSTANT], payloads)
    assert violations == []


def test_constant_matches_every_event_name_under_a_star_claim() -> None:
    # signal_name '*' is the registry grain for "any event name" — a second value under
    # a *different* event name is still drift.
    payloads = [_event("auth", s, {"safe_mode": "false"}) for s in _seats(11)]
    payloads.append(_event("tool_result", "x@itworx.com", {"safe_mode": "true"}))
    violations, _, _ = _run([CONSTANT], payloads)
    assert len(violations) == 1


def test_named_grain_claim_ignores_other_event_names() -> None:
    claim = Claim("events", "auth", "action", "constant", None)
    payloads = [_event("auth", s, {"action": "login"}) for s in _seats(11)]
    payloads.append(_event("logout_event", "x@itworx.com", {"action": "logout"}))
    violations, _, _ = _run([claim], payloads)
    assert violations == []


# --- collinear ----------------------------------------------------------------

OS_VERSION = Claim("resource", "*", "os.version", "collinear", "os.type")
WSL_VERSION = Claim("resource", "*", "wsl.version", "collinear", "os.type")


def test_collinear_clean_when_partner_determines_the_value() -> None:
    payloads = [
        _resource(s, {"os.type": "windows", "os.version": "10.0.26200"}) for s in _seats(10)
    ]
    payloads += [_resource(s, {"os.type": "linux", "os.version": "6.6.87"}) for s in _seats(4)]
    violations, _, _ = _run([OS_VERSION], payloads)
    assert violations == []


def test_collinear_violated_by_a_value_split_in_one_partner_group() -> None:
    # The mixed-Windows-build case: two builds under os.type='windows'.
    payloads = [
        _resource(s, {"os.type": "windows", "os.version": "10.0.26200"}) for s in _seats(10)
    ]
    payloads.append(_resource("new@itworx.com", {"os.type": "windows", "os.version": "10.0.27000"}))
    violations, _, _ = _run([OS_VERSION], payloads)
    assert len(violations) == 1
    assert violations[0].basis == "collinear"
    assert "windows" in violations[0].evidence
    assert "10.0.26200" in violations[0].evidence and "10.0.27000" in violations[0].evidence


def test_collinear_clean_on_a_pure_presence_dependency() -> None:
    # wsl.version is present iff os.type='linux' — windows -> absent, linux -> '2'.
    payloads = [_resource(s, {"os.type": "windows"}) for s in _seats(10)]
    payloads += [_resource(s, {"os.type": "linux", "wsl.version": "2"}) for s in _seats(4)]
    violations, _, _ = _run([WSL_VERSION], payloads)
    assert violations == []


def test_collinear_violated_by_a_presence_split_native_linux() -> None:
    # The native, non-WSL Linux seat: the 'linux' group now holds {'2', absent}.
    # Counting absence as a value is what catches this with the same predicate.
    payloads = [_resource(s, {"os.type": "windows"}) for s in _seats(10)]
    payloads += [_resource(s, {"os.type": "linux", "wsl.version": "2"}) for s in _seats(3)]
    payloads.append(_resource("native@itworx.com", {"os.type": "linux"}))
    violations, _, _ = _run([WSL_VERSION], payloads)
    assert len(violations) == 1
    assert "linux" in violations[0].evidence
    assert "(absent)" in violations[0].evidence


def test_collinear_absent_partner_is_its_own_group() -> None:
    # A record carrying neither key is one consistent group (absent -> absent), so a
    # partner that is itself missing does not manufacture drift on its own.
    payloads = [_resource(s, {}) for s in _seats(10)]
    violations, _, _ = _run([WSL_VERSION], payloads)
    assert violations == []


# --- thin ---------------------------------------------------------------------

HOST_PATHS = Claim("events", "*", "workspace.host_paths", "thin", None)


def test_thin_clean_below_the_share() -> None:
    seats = _seats(20)
    payloads = [_event("tool_result", s, {}) for s in seats]
    payloads += [_event("tool_result", s, {"workspace.host_paths": "/c/x"}) for s in seats[:3]]
    violations, evaluated, population = _run([HOST_PATHS], payloads)
    assert (violations, evaluated, population) == ([], True, 20)


def test_thin_violated_at_half_the_fleet() -> None:
    seats = _seats(20)
    payloads = [_event("tool_result", s, {}) for s in seats]
    payloads += [_event("tool_result", s, {"workspace.host_paths": "/c/x"}) for s in seats[:10]]
    violations, evaluated, _ = _run([HOST_PATHS], payloads)
    assert evaluated
    assert len(violations) == 1
    assert violations[0].basis == "thin"
    assert "10 of 20" in violations[0].evidence


def test_thin_not_evaluated_below_the_seat_floor() -> None:
    # A quiet window false-alarms: 2 of 4 reporting seats reads 50% for a key that
    # reaches one seat in twenty. Both sides of the ratio shrink, so the guard is a
    # floor on the population, not on the numerator.
    seats = _seats(4)
    payloads = [_event("tool_result", s, {}) for s in seats]
    payloads += [_event("tool_result", s, {"workspace.host_paths": "/c/x"}) for s in seats[:2]]
    violations, evaluated, population = _run([HOST_PATHS], payloads)
    assert (violations, evaluated, population) == ([], False, 4)


def test_constant_and_collinear_are_evaluated_below_the_seat_floor() -> None:
    # They need a single counterexample, so a short window can miss drift but never
    # invent it — no guard, unlike `thin`.
    payloads = [
        _event("auth", "a@itworx.com", {"safe_mode": "false"}),
        _event("auth", "b@itworx.com", {"safe_mode": "true"}),
    ]
    violations, evaluated, population = _run([CONSTANT], payloads)
    assert not evaluated  # thin would have been skipped at this population
    assert len(violations) == 1  # ...but constant still fired


# --- the bases with no machine predicate --------------------------------------


def test_nature_and_redundant_are_never_evaluated() -> None:
    claims = [
        Claim("events", "*", "user.id", "nature", None),
        Claim("events", "tool_decision", "tool_source", "redundant", None),
    ]
    payloads = [_event("tool_decision", s, {"user.id": s, "tool_source": s}) for s in _seats(20)]
    violations, _, _ = _run(claims, payloads)
    assert violations == []


def test_unevaluated_bases_are_counted_not_hidden() -> None:
    claims = [
        Claim("events", "*", "user.id", "nature", None),
        Claim("events", "tool_decision", "tool_source", "redundant", None),
        CONSTANT,
    ]
    profile = BasisProfile(claims)
    profile.update([_event("auth", "a@itworx.com", {"safe_mode": "false"})])
    report = evaluate(profile)
    assert report.exempt == {"nature": 1, "redundant": 1}
    assert report.checked == 1


# --- reporting ----------------------------------------------------------------


def test_report_names_the_key_its_basis_and_the_evidence() -> None:
    payloads = [_event("auth", s, {"safe_mode": "false"}) for s in _seats(11)]
    payloads.append(_event("auth", "new@itworx.com", {"safe_mode": "true"}))
    profile = BasisProfile([CONSTANT])
    profile.update(payloads)
    text = format_report(evaluate(profile), [])
    assert "safe_mode" in text
    assert "constant" in text
    assert "events" in text


def test_report_states_the_thin_skip_with_the_observed_population() -> None:
    profile = BasisProfile([HOST_PATHS])
    profile.update([_event("tool_result", s, {}) for s in _seats(4)])
    text = format_report(evaluate(profile), [])
    assert "thin NOT EVALUATED" in text  # never a silent skip
    assert f"at least {THIN_SEAT_FLOOR}" in text  # the requirement
    assert "4 reporting seats" in text  # the observed population


def test_thin_share_and_floor_are_the_briefed_values() -> None:
    assert THIN_SHARE == 0.5
    assert THIN_SEAT_FLOOR == 10
