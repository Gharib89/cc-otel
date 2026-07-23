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
        # Reservoir & marts overview

        On-demand EDA seed over the redacted-raw OTLP reservoir (ADR-0005) and the
        Postgres marts. The blob reservoir holds a superset of what schema-v2
        promotes; this notebook counts what is there before the focused notebooks
        (`promotion_candidates`, `redaction_audit`, `ecosystem`) drill in.
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

    from analysis._common import read_payloads
    from tools._reservoir import configure_duckdb
    from tools._window import SIGNALS, resolve_window

    return (
        SIGNALS,
        UTC,
        configure_duckdb,
        datetime,
        duckdb,
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
    return (days, settings, window_days)


@app.cell
def _(SIGNALS, configure_duckdb, days, duckdb, read_payloads, settings):
    con = duckdb.connect()
    configure_duckdb(con, settings)
    payloads = read_payloads(con, settings.blob_container, SIGNALS, days)
    con.close()
    return (payloads,)


@app.cell
def _(mo, payloads, window_days):
    n_metrics = sum(1 for p in payloads if p.get("resourceMetrics"))
    n_logs = sum(1 for p in payloads if p.get("resourceLogs"))
    mo.md(
        f"""
        **Window:** last {window_days} days &nbsp;|&nbsp; **export blobs read:** {len(payloads)}

        | signal | export blobs |
        |---|--:|
        | metrics | {n_metrics} |
        | logs | {n_logs} |
        """
    )
    return


@app.cell
def _(mo):
    mo.md("## Marts & column registry (Postgres)")
    return


@app.cell
def _(psycopg, settings):
    with psycopg.connect(settings.database_url) as pg:
        matviews = pg.execute(
            "SELECT schemaname, matviewname FROM pg_matviews ORDER BY 1, 2"
        ).fetchall()
        registry_status = pg.execute(
            "SELECT status, count(*) FROM meta.column_registry GROUP BY status ORDER BY status"
        ).fetchall()
    return (matviews, registry_status)


@app.cell
def _(matviews, mo, registry_status):
    mo.vstack(
        [
            mo.md("**Materialized marts (dims/facts):**"),
            mo.ui.table([{"schema": s, "matview": m} for s, m in matviews], selection=None),
            mo.md("**Column-registry status breakdown:**"),
            mo.ui.table([{"status": s, "keys": n} for s, n in registry_status], selection=None),
        ]
    )
    return


if __name__ == "__main__":
    app.run()
