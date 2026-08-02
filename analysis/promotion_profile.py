import marimo

__generated_with = "0.23.14"
app = marimo.App(width="medium")


@app.cell
def _():
    import marimo as mo

    return (mo,)


@app.cell
def _(mo):
    mo.md("""
    # Promotion-candidate profile (record grain)

    The wide-window companion to `promotion_candidates.py` (#351). That notebook ranks
    **kept** / **unclassified** key paths by *blob* fill rate over a short window; this
    one profiles them at **record** grain over the whole reconciled window, and adds the
    cross-tabs a value case actually needs:

    - **fill %** — records carrying the key, as a share of its signal-name population
      (not of all blobs), so a key on a rare event is not diluted by a busy one.
    - **sessions / seats** — how many distinct sessions and developers the key reaches.
      A key at 45% fill concentrated in two seats is a different proposition from one
      spread across the roster.
    - **cardinality + examples** — the column-sizing evidence, capped at `VALUE_CAP`
      distinct values (`capped = True` means "more than the cap", itself a verdict).

    `resource_dup` flags a key already registered as a `resource/*` attribute and merely
    seen again under a signal path — the same fact at a second key path, not a candidate
    (registry hygiene owns those).
    """)
    return


@app.cell
def _():
    import sys
    from pathlib import Path

    # marimo puts the notebook's own dir on sys.path, not the repo root; add the
    # root so the source-only `tools`/`analysis` packages import (cc_otel_sink is
    # installed, so it needs no help). Run notebooks from the repo root.
    _root = str(Path(__file__).resolve().parents[1])
    if _root not in sys.path:
        sys.path.insert(0, _root)

    from datetime import UTC, date, datetime

    import duckdb
    import psycopg
    from cc_otel_sink.config import load_settings

    from analysis._common import Profile, load_env, read_payloads
    from tools._registry import load_registry
    from tools._reservoir import configure_duckdb
    from tools._window import date_range
    from tools.signals import ROUTES

    # No shell sourced the env file into this kernel — load it before the cell
    # below builds Settings (`CC_OTEL_ENV_FILE` picks a file other than .env.interim).
    load_env()

    return (
        ROUTES,
        UTC,
        Profile,
        configure_duckdb,
        date,
        date_range,
        datetime,
        duckdb,
        load_registry,
        load_settings,
        psycopg,
        read_payloads,
    )


@app.cell
def _(UTC, date, date_range, datetime, load_settings):
    # Jul 17 is the reconciled floor — it reconciles exactly (234 = 234 raw.metrics,
    # 13,628 = 13,628 raw.events), corrected from Jul 18 by #379. Jul 14-16 stay out:
    # their metrics blobs do not reconcile with raw rows (7,617 rows vs 3 blobs on Jul 14).
    since = date(2026, 7, 17)
    until = datetime.now(UTC).date()
    settings = load_settings()
    days = date_range(since, until)

    return days, settings


@app.cell
def _(ROUTES, Profile, configure_duckdb, days, duckdb, read_payloads, settings):
    # ~30s of network read per uncompacted day of blobs (~1s once compacted, ADR-0015), so
    # the window streams day by day and aggregates as it goes rather than holding every
    # payload at once.
    profile = Profile()
    blobs_per_day = {}
    con = duckdb.connect()
    try:
        configure_duckdb(con, settings)
        for _day in days:
            try:
                _payloads = read_payloads(
                    con, settings.blob_container, ROUTES, [_day], settings.blob_compacted_container
                )
            except duckdb.IOException:
                # `configure_duckdb` pins one prefetched OAuth token and a multi-day read
                # outlives it (`InvalidAuthenticationInfo` partway through the window).
                # Re-register once and retry; a second failure is real and propagates.
                configure_duckdb(con, settings)
                _payloads = read_payloads(
                    con, settings.blob_container, ROUTES, [_day], settings.blob_compacted_container
                )
            profile.update(_payloads)
            blobs_per_day[_day] = len(_payloads)
    finally:
        con.close()

    return blobs_per_day, profile


@app.cell
def _(load_registry, profile, psycopg, settings):
    with psycopg.connect(settings.database_url) as _pg:
        registry = load_registry(_pg)

    def _pct(part: int, whole: int) -> float:
        return round(100 * part / whole, 1) if whole else 0.0

    rows = []
    for (_signal, _name, _attr), _s in profile.keys.items():
        _pop = profile.populations[(_signal, _name)]
        rows.append(
            {
                "signal": _signal,
                "signal_name": _name,
                "attr_path": _attr,
                "status": registry.status_of(_signal, _name, _attr) or "unclassified",
                "resource_dup": _signal != "resource"
                and registry.status_of("resource", "*", _attr) is not None,
                "records": _s.records,
                "fill_pct": _pct(_s.records, _pop.records),
                "sessions": len(_s.sessions),
                "session_pct": _pct(len(_s.sessions), len(_pop.sessions)),
                "seats": len(_s.seats),
                "seat_pct": _pct(len(_s.seats), len(_pop.seats)),
                "cardinality": len(_s.values),
                "capped": _s.capped,
                "examples": ", ".join(v for v, _ in _s.values.most_common(3)),
            }
        )
    rows.sort(key=lambda r: -r["records"])
    candidates = [
        r for r in rows if r["status"] in ("kept", "unclassified") and not r["resource_dup"]
    ]

    return candidates, rows


@app.cell
def _(blobs_per_day, candidates, mo, profile, rows):
    mo.vstack(
        [
            mo.md(
                f"**{sum(blobs_per_day.values()):,} blobs** over {len(blobs_per_day)} days · "
                f"**{sum(p.records for p in profile.populations.values()):,} records** · "
                f"{len(rows)} key paths, of which **{len(candidates)} candidates** "
                "(kept or unclassified, resource duplicates excluded):"
            ),
            mo.ui.table(candidates, selection=None),
        ]
    )

    return


@app.cell
def _(mo, rows):
    mo.vstack(
        [
            mo.md("Every key path, including promoted and resource duplicates:"),
            mo.ui.table(rows, selection=None),
        ]
    )

    return


if __name__ == "__main__":
    app.run()
