import marimo

__generated_with = "0.23.14"
app = marimo.App(width="medium")


@app.cell
def _():
    import marimo as mo

    return (mo,)


@app.cell
def _(mo):
    mo.md(
        """
        # Redaction-leak audit

        Key paths classified **denied** in `meta.column_registry` yet still present in
        the redacted-raw reservoir — each is a redaction the sink missed (#8). Mirrors
        the `tools.sweep` leak bucket, but ranks leaks by how many export blobs carry
        them so the worst offenders surface first. A clean run shows zero leaks.
        """
    )
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

    from datetime import UTC, datetime

    import duckdb
    import psycopg
    from cc_otel_sink.config import load_settings

    from analysis._common import fill_counts, read_payloads
    from tools._registry import load_registry
    from tools._reservoir import configure_duckdb
    from tools._window import SIGNALS, resolve_window

    return (
        SIGNALS,
        UTC,
        configure_duckdb,
        datetime,
        duckdb,
        fill_counts,
        load_registry,
        load_settings,
        psycopg,
        read_payloads,
        resolve_window,
    )


@app.cell
def _(UTC, datetime, load_settings, resolve_window):
    # Reservoir reads are network-bound (~30s per day of blobs); a small default
    # keeps the notebook snappy. Widen as needed — Parquet compaction is the fix
    # if wide windows bite (#87). Inclusive window ending today (UTC).
    window_days = 3
    settings = load_settings()
    days = resolve_window(window_days, None, None, datetime.now(UTC).date())
    return (days, settings)


@app.cell
def _(SIGNALS, configure_duckdb, days, duckdb, read_payloads, settings):
    con = duckdb.connect()
    configure_duckdb(con, settings)
    payloads = read_payloads(con, settings.blob_container, SIGNALS, days)
    con.close()
    return (payloads,)


@app.cell
def _(fill_counts, payloads):
    fill = fill_counts(payloads)  # blob-level: how many payloads carry each key path
    return (fill,)


@app.cell
def _(fill, load_registry, psycopg, settings):
    with psycopg.connect(settings.database_url) as _pg:
        registry = load_registry(_pg)
    diff = registry.diff(set(fill))
    leaks = [
        {"signal": _s, "signal_name": _n, "attr_path": _a, "blobs": fill[(_s, _n, _a)]}
        for (_s, _n, _a) in diff.leaks
    ]
    leaks.sort(key=lambda r: r["blobs"], reverse=True)
    return (leaks,)


@app.cell
def _(leaks, mo):
    mo.vstack(
        [
            mo.md(f"**{len(leaks)} redaction leak(s)** — DENIED keys found in redacted blobs:"),
            mo.ui.table(leaks, selection=None) if leaks else mo.md("No leaks — redaction clean."),
        ]
    )
    return


if __name__ == "__main__":
    app.run()
