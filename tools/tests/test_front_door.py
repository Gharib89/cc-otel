from datetime import UTC, date, datetime, timedelta

import pytest

from tools import front_door
from tools.front_door import (
    ACCEPTED,
    RETENTION,
    SILENCE_DAYS,
    Day,
    az_executable,
    daily_counts,
    format_report,
    main,
    silent_days,
    window,
)

SUB = "58b41413-7eb2-454f-92a9-ffbe6b30efc6"
RG = "rg-cc-otel-interim"


def _series(code: str, points: dict[str, float | None]) -> dict:
    return {
        "metadatavalues": [{"name": {"value": "statuscode"}, "value": code}],
        "data": [{"timeStamp": t, "total": v} for t, v in points.items()],
    }


def _payload(*series: dict) -> dict:
    return {"value": [{"name": {"value": "Requests"}, "timeseries": list(series)}]}


def _days(first: str, last: str) -> list[date]:
    return window(0, date.fromisoformat(first), date.fromisoformat(last), date.fromisoformat(last))


# --- daily_counts: hourly points folded into UTC days -------------------------------


def test_daily_counts_sums_hourly_points_into_utc_days():
    payload = _payload(
        _series("200", {"2026-08-04T05:00:00Z": 146.0, "2026-08-04T06:00:00Z": 197.0}),
    )

    (row,) = daily_counts(payload, [date(2026, 8, 4)])

    assert row.day == date(2026, 8, 4)
    assert row.counts == {"200": 343}


def test_daily_counts_keeps_the_status_codes_apart():
    # The whole point of `--filter "statusCode eq '*'"`: an undifferentiated total cannot tell
    # accepted ingest from a rejected post, and a rejected payload is dropped rather than queued.
    payload = _payload(
        _series("200", {"2026-08-04T05:00:00Z": 1367.0}),
        _series("401", {"2026-08-04T05:00:00Z": 1348.0}),
        _series("404", {"2026-08-04T05:00:00Z": 3.0}),
    )

    (row,) = daily_counts(payload, [date(2026, 8, 4)])

    assert row.counts == {"200": 1367, "401": 1348, "404": 3}
    assert (row.accepted, row.rejected) == (1367, 1351)


def test_daily_counts_reports_a_day_with_no_traffic_as_zero_not_as_absent():
    # A status code only gets a timeseries on the days it occurred. A payload-derived day grid
    # would drop the silent day entirely — and a dropped day cannot break a silence run.
    payload = _payload(_series("200", {"2026-08-05T09:00:00Z": 374.0}))

    rows = daily_counts(payload, _days("2026-08-05", "2026-08-07"))

    assert [(row.day.day, row.accepted) for row in rows] == [(5, 374), (6, 0), (7, 0)]


def test_daily_counts_ignores_hours_azure_returned_no_total_for():
    payload = _payload(
        _series("200", {"2026-08-05T09:00:00Z": None, "2026-08-05T10:00:00Z": 12.0}),
    )

    (row,) = daily_counts(payload, [date(2026, 8, 5)])

    assert row.counts == {"200": 12}


def test_daily_counts_ignores_a_series_with_no_status_code_dimension():
    payload = _payload(
        {"metadatavalues": [], "data": [{"timeStamp": "2026-08-05T09:00Z", "total": 9}]}
    )

    (row,) = daily_counts(payload, [date(2026, 8, 5)])

    assert row.counts == {}


# --- az_executable -------------------------------------------------------------------


def test_az_executable_resolves_the_windows_cmd_shim(monkeypatch):
    # A bare `["az", ...]` argv raises WinError 2 on Windows, where the CLI is `az.cmd`.
    monkeypatch.setattr(front_door.shutil, "which", lambda _name: "C:/az/wbin/az.cmd")

    assert az_executable() == "C:/az/wbin/az.cmd"


def test_az_executable_falls_back_to_the_bare_name_when_the_cli_is_absent(monkeypatch):
    monkeypatch.setattr(front_door.shutil, "which", lambda _name: None)

    assert az_executable() == "az"


# --- silent_days: the arithmetic the go/no-go reads -----------------------------------


def _rows(accepted_per_day: dict[str, int]) -> list[Day]:
    return [
        Day(date.fromisoformat(d), {ACCEPTED: n} if n else {}) for d, n in accepted_per_day.items()
    ]


def test_silent_days_counts_back_from_the_newest_complete_day():
    rows = _rows({"2026-08-01": 985, "2026-08-02": 0, "2026-08-03": 0})

    assert silent_days(rows, today=date(2026, 8, 4)) == 2


def test_silent_days_excludes_today_because_it_is_still_accruing():
    # A morning with no posts yet is not a day without posts. Counting it would open the gate
    # hours early — the one direction this measurement must never fail in.
    rows = _rows({"2026-08-04": 0, "2026-08-05": 0})

    assert silent_days(rows, today=date(2026, 8, 5)) == 1


def test_silent_days_stops_at_the_last_day_that_had_traffic():
    rows = _rows({"2026-08-01": 0, "2026-08-02": 0, "2026-08-03": 7, "2026-08-04": 0})

    assert silent_days(rows, today=date(2026, 8, 5)) == 1


def test_silent_days_ignores_rejected_posts():
    # A `401` day proves a client is still pointed here, but the run counts accepted posts:
    # rejection is the *reason* the payload was lost, not evidence the door went quiet.
    rows = [Day(date(2026, 8, 4), {"401": 1348})]

    assert silent_days(rows, today=date(2026, 8, 5)) == 1


def test_silent_days_is_zero_when_the_window_holds_no_complete_day():
    assert silent_days(_rows({"2026-08-05": 0}), today=date(2026, 8, 5)) == 0


# --- window ---------------------------------------------------------------------------


def test_window_ends_today_so_a_partial_day_is_still_reported():
    days = window(3, None, None, date(2026, 8, 6))

    assert days == [date(2026, 8, 4), date(2026, 8, 5), date(2026, 8, 6)]


def test_window_since_overrides_the_day_count():
    days = window(2, date(2026, 8, 1), date(2026, 8, 4), date(2026, 8, 6))

    assert days == [date(2026, 8, d) for d in (1, 2, 3, 4)]


# --- format_report --------------------------------------------------------------------


def test_format_report_marks_the_incomplete_day_and_names_the_lost_posts():
    rows = daily_counts(
        _payload(
            _series("200", {"2026-08-05T09:00:00Z": 374.0, "2026-08-06T09:00:00Z": 267.0}),
            _series("401", {"2026-08-05T09:00:00Z": 1348.0}),
        ),
        _days("2026-08-05", "2026-08-06"),
    )

    report = format_report(rows, "ccotel-app-interim", run=0, today=date(2026, 8, 6))

    assert "(partial day)" in report.splitlines()[-3]
    assert "1348 post(s)" in report
    assert "STILL RECEIVING: 0 consecutive complete day(s)" in report


def test_format_report_calls_a_long_enough_run_silent():
    rows = _rows(dict.fromkeys([f"2026-08-{d:02d}" for d in range(1, 9)], 0))

    report = format_report(rows, "ccotel-app-interim", run=SILENCE_DAYS, today=date(2026, 8, 9))

    assert f"SILENT: {SILENCE_DAYS} consecutive complete day(s)" in report
    assert "Rejected in window" not in report


# --- CLI ---------------------------------------------------------------------------------


@pytest.fixture
def az(monkeypatch):
    """Stand in for the `az monitor metrics list` call, recording how it was addressed."""
    calls = []

    def _az(payload):
        def _fetch(subscription, resource_group, app, days):
            calls.append((subscription, resource_group, app, days))
            return payload

        monkeypatch.setattr(front_door, "fetch", _fetch)
        return calls

    return _az


def _yesterday_silent_payload() -> dict:
    """Traffic that stopped SILENCE_DAYS complete days ago — the shape that opens the gate."""
    stopped = datetime.now(UTC).date() - timedelta(days=SILENCE_DAYS + 1)
    return _payload(_series("200", {f"{stopped:%Y-%m-%d}T09:00:00Z": 500.0}))


def test_main_needs_a_subscription_and_a_resource_group(monkeypatch, capsys):
    monkeypatch.delenv("AZURE_SUBSCRIPTION_ID", raising=False)
    monkeypatch.delenv("RESOURCE_GROUP", raising=False)

    assert main([]) == 2
    assert "AZURE_SUBSCRIPTION_ID" in capsys.readouterr().err


def test_main_derives_the_app_name_from_the_environment(az, capsys):
    calls = az(_payload())

    main(["--env", "prod", "--subscription", SUB, "--resource-group", "rg-cc-otel-prod"])

    assert calls[0][2] == "ccotel-app-prod"
    assert "ccotel-app-prod" in capsys.readouterr().out


def test_main_refuses_a_window_older_than_platform_metric_retention(az, capsys):
    az(_payload())
    stale = datetime.now(UTC).date() - RETENTION - timedelta(days=1)

    assert (
        main(["--since", f"{stale:%Y-%m-%d}", "--subscription", SUB, "--resource-group", RG]) == 2
    )

    err = capsys.readouterr().err
    assert "retention" in err and "read as silence" in err


def test_main_exits_1_while_the_front_door_is_still_receiving(az, capsys):
    today = datetime.now(UTC).date()
    az(_payload(_series("200", {f"{today - timedelta(days=1):%Y-%m-%d}T09:00:00Z": 267.0})))

    assert main(["--subscription", SUB, "--resource-group", RG]) == 1
    assert "STILL RECEIVING" in capsys.readouterr().out


def test_main_exits_0_once_the_silence_run_reaches_the_required_length(az, capsys):
    az(_yesterday_silent_payload())

    assert main(["--days", "30", "--subscription", SUB, "--resource-group", RG]) == 0
    assert "SILENT" in capsys.readouterr().out


def test_main_reports_the_metric_being_unreadable_as_tooling_not_as_silence(monkeypatch, capsys):
    # An `az` that cannot answer must never be mistaken for a door with no traffic.
    def _boom(*_args):
        raise RuntimeError("Please run 'az login' to setup account.")

    monkeypatch.setattr(front_door, "fetch", _boom)

    assert main(["--subscription", SUB, "--resource-group", RG]) == 2
    err = capsys.readouterr().err
    assert "az login" in err and "SILENT" not in err
