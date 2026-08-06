"""Measure a **front door**: accepted and rejected posts per day at one environment's (#431).

Every other quiet-check in this repo reads a *store* -- ``meta.processed_batches`` for raw rows
(ADR-0021), the newest blob name for the reservoir. After the **ingest repoint** those stores
answer about production, not about the front door a **tracked machine** actually posts to, so
they read green while interim's collector is in active use. This tool reads the front door
itself, off the Container App's ``Requests`` platform metric split by ``statusCode``.

The verdict it prints is evidence for #248 Part B's human go/no-go, not an automatic gate:
``az group delete rg-cc-otel-interim`` under live traffic drops those payloads silently, because
the client collector retries forever into a dead host and buffers (ADR-0027).

    uv run python -m tools.front_door                  # interim, the last 14 days
    uv run python -m tools.front_door --env prod
    uv run python -m tools.front_door --since 2026-07-30 --until 2026-08-06
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import UTC, date, datetime, time, timedelta
from typing import NamedTuple

# The Container App is named `ccotel-app-<env>` on both targets (deploy.yml,
# bootstrap/lib/Get-BootstrapConfig.ps1), so the environment name is all an operator has to know.
APP_NAME = "ccotel-app-{env}"
ENVIRONMENTS = ("interim", "prod")
RESOURCE_TYPE = "Microsoft.App/containerapps"

# A post the collector accepted. Anything else was rejected before the sink saw it -- a `401`
# payload is dropped, never queued, so the rejected columns are live data loss, not retry noise.
ACCEPTED = "200"

# ADR-0027's silence window. A constant rather than a flag for the same reason ADR-0021 refused a
# `--force` twin: the decision it feeds is irreversible, and a knob invites lowering it under time
# pressure. Seven days covers a full working week, so a seat that only works Mondays cannot hide
# inside the window.
SILENCE_DAYS = 7

# Azure platform-metric retention. The load-bearing guard: outside it the API answers with an empty
# series rather than an error, so "no requests" and "no data" are indistinguishable and a window
# reaching too far back would read as silence on exactly the days nothing is known about.
RETENTION = timedelta(days=93)

DEFAULT_DAYS = 14


class Day(NamedTuple):
    """One UTC day at one front door: requests per HTTP status code."""

    day: date
    counts: dict[str, int]

    @property
    def accepted(self) -> int:
        return self.counts.get(ACCEPTED, 0)

    @property
    def rejected(self) -> int:
        return sum(n for code, n in self.counts.items() if code != ACCEPTED)


def window(days: int, since: date | None, until: date | None, today: date) -> list[date]:
    """The UTC days to report on, oldest first.

    ``until`` defaults to *today* rather than yesterday: the partial day is reported, and
    :func:`silent_days` is what excludes it from the verdict. An operator asking "is it quiet
    right now" should see this morning's traffic, not have it silently withheld.
    """
    last = until or today
    first = since or last - timedelta(days=days - 1)
    return [first + timedelta(days=n) for n in range((last - first).days + 1)]


def az_executable() -> str:
    """The ``az`` entry point to exec, resolved through ``PATH``.

    On Windows the CLI ships as ``az.cmd``, which a bare ``["az", ...]`` argv cannot find without
    a shell -- ``shutil.which`` consults ``PATHEXT`` and returns the real path. Falling back to the
    bare name keeps the failure as a plain "not found" on a machine with no CLI at all.
    """
    return shutil.which("az") or "az"


def fetch(subscription: str, resource_group: str, app: str, days: list[date]) -> dict:
    """Raw ``az monitor metrics list`` JSON for ``Requests`` over ``days``, split by status code.

    Addressed by ``--resource <name> --resource-group`` rather than the full resource ID: git-bash
    rewrites a leading ``/subscriptions/...`` into a Windows path and ``az`` then rejects it with a
    misleading usage error, so the name form is the portable one (#431).

    ``--interval PT1H`` is not just resolution. The hourly shape is what separates real client
    traffic from probe noise -- a liveness probe is constant across every hour, a fleet is not --
    and a daily interval loses that discrimination for anyone re-reading the run's evidence.
    """
    result = subprocess.run(
        [
            az_executable(), "monitor", "metrics", "list",
            "--subscription", subscription,
            "--resource", app,
            "--resource-group", resource_group,
            "--resource-type", RESOURCE_TYPE,
            "--metric", "Requests",
            "--interval", "PT1H",
            "--aggregation", "Total",
            # Splits the timeseries per status code. Without it the response is one
            # undifferentiated total and accepted ingest cannot be told from rejected posts.
            "--filter", "statusCode eq '*'",
            "--start-time", f"{datetime.combine(days[0], time.min, tzinfo=UTC):%Y-%m-%dT%H:%M:%SZ}",
            "--end-time", f"{datetime.combine(days[-1], time.max, tzinfo=UTC):%Y-%m-%dT%H:%M:%SZ}",
            "-o", "json",
        ],
        capture_output=True,
        text=True,
        check=False,
    )  # fmt: skip
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"az exited {result.returncode}")
    return json.loads(result.stdout)


def daily_counts(payload: dict, days: list[date]) -> list[Day]:
    """Hourly points folded into one row per requested UTC day, oldest first.

    The day grid comes from ``days``, not from the payload: a status code only gets a timeseries
    on the days it occurred, so a payload-derived grid would drop a silent day entirely instead of
    reporting it as zero -- and a dropped day cannot break a silence run that it should break.
    """
    totals: dict[date, dict[str, int]] = {day: {} for day in days}
    for metric in payload.get("value", []):
        for series in metric.get("timeseries", []):
            code = next(
                (
                    meta["value"]
                    for meta in series.get("metadatavalues", [])
                    if meta.get("name", {}).get("value") == "statuscode"
                ),
                None,
            )
            if code is None:
                continue
            for point in series.get("data", []):
                # `total` is absent or null for an hour with no requests -- an hour Azure has no
                # data for looks the same, which is what RETENTION exists to keep out of range.
                total = point.get("total")
                if not total:
                    continue
                day = date.fromisoformat(point["timeStamp"][:10])
                if day in totals:
                    totals[day][code] = totals[day].get(code, 0) + int(total)
    return [Day(day, totals[day]) for day in days]


def silent_days(rows: list[Day], today: date) -> int:
    """Consecutive **complete** days with zero accepted posts, counted back from **yesterday**.

    Two exclusions, both in the conservative direction:

    *Today* never counts -- it is still accruing, so a morning with no posts yet is not a day
    without posts, and counting it would open the gate hours early.

    The run is anchored at yesterday rather than at the newest row, so a window that stops short of
    yesterday scores **zero** however quiet it was. Otherwise ``--until`` a month back would report
    a seven-day run that ended weeks ago and exit ``SILENT`` on evidence saying nothing about now.
    A day the window does not cover is unknown, and unknown is never silence.
    """
    accepted = {row.day: row.accepted for row in rows}
    run = 0
    day = today - timedelta(days=1)
    while accepted.get(day) == 0:
        run += 1
        day -= timedelta(days=1)
    return run


def format_report(rows: list[Day], app: str, run: int, today: date) -> str:
    """The per-day table, then the verdict the human go/no-go reads."""
    codes = sorted({code for row in rows for code in row.counts})
    lines = [f"Front door {app} — requests per UTC day, by status code"]
    for row in rows:
        counts = (
            "  ".join(f"{code} {row.counts.get(code, 0):>6}" for code in codes) or "(no requests)"
        )
        partial = "  (partial day)" if row.day >= today else ""
        lines.append(f"  {row.day:%Y-%m-%d}  {counts}{partial}")
    rejected = sum(row.rejected for row in rows)
    if rejected:
        lines.append(
            f"Rejected in window: {rejected} post(s) — a rejected payload is dropped, not queued,"
            " so these are lost rows, not retries"
        )
    verdict = "SILENT" if run >= SILENCE_DAYS else "STILL RECEIVING"
    lines.append(
        f"{verdict}: {run} consecutive complete day(s) with zero {ACCEPTED}s,"
        f" of the {SILENCE_DAYS} ADR-0027 requires before retiring a front door"
    )
    return "\n".join(lines)


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--env", choices=ENVIRONMENTS, default="interim", help="which front door")
    p.add_argument("--days", type=int, default=DEFAULT_DAYS, help="window length (default 14)")
    p.add_argument("--since", type=date.fromisoformat, help="first UTC day; overrides --days")
    p.add_argument("--until", type=date.fromisoformat, help="last UTC day (default today)")
    p.add_argument("--subscription", help="default $AZURE_SUBSCRIPTION_ID")
    p.add_argument("--resource-group", help="default $RESOURCE_GROUP")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    subscription = args.subscription or os.environ.get("AZURE_SUBSCRIPTION_ID")
    resource_group = args.resource_group or os.environ.get("RESOURCE_GROUP")
    if not subscription or not resource_group:
        print(
            "Need both: pass --subscription/--resource-group or source the target environment's"
            " .env.<env> (AZURE_SUBSCRIPTION_ID, RESOURCE_GROUP). Interim lives in the VS"
            " Enterprise subscription, not the default one, so neither is optional.",
            file=sys.stderr,
        )
        return 2

    app = APP_NAME.format(env=args.env)
    today = datetime.now(UTC).date()
    days = window(args.days, args.since, args.until, today)
    # Named before the call, as `tools.reservoir_copy` names its two accounts: a subscription and
    # an environment that disagree would silently measure the wrong front door and report silence.
    print(f"Front door:   {app}  (subscription {subscription}, {resource_group})")
    if not days:
        # `--days 0`, or a `--since` past its `--until`. Refused rather than clamped: the operator
        # asked a question with no days in it, and every later step here reads `days[0]`.
        print(
            "Refused: that window holds no days — check --days / --since / --until",
            file=sys.stderr,
        )
        return 2
    print(f"Window:       {days[0]:%Y-%m-%d} .. {days[-1]:%Y-%m-%d} UTC ({len(days)} day(s))")
    if days[0] < today - RETENTION:
        print(
            f"Refused: {days[0]:%Y-%m-%d} is outside Azure's {RETENTION.days}-day platform-metric"
            " retention. Beyond it the API returns an empty series rather than an error, so"
            " unretained days would read as silence — the one way this measurement must not fail.",
            file=sys.stderr,
        )
        return 2

    try:
        payload = fetch(subscription, resource_group, app, days)
    except (OSError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"Could not read the metric: {exc}", file=sys.stderr)
        print("Needs `az login` with Monitoring Reader on the resource group.", file=sys.stderr)
        return 2

    rows = daily_counts(payload, days)
    run = silent_days(rows, today)
    print(format_report(rows, app, run, today))
    return 0 if run >= SILENCE_DAYS else 1


if __name__ == "__main__":
    sys.exit(main())
