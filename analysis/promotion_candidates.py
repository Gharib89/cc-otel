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
        # Promotion-candidate mining

        Blob-reservoir attribute keys that are **kept** (blob-only) or **unclassified**
        — the candidates to promote into the marts via the #16 curation flow. For each
        key path this shows how many export blobs in the window carry it (fill rate);
        high-fill kept keys are the strongest promotion candidates.

        Complements `tools.sweep` (which reports the drift verdict); this ranks the
        candidates by prevalence so curation can triage.
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

    from collections import Counter
    from datetime import UTC, datetime

    import duckdb
    import psycopg
    from cc_otel_sink.config import load_settings

    from analysis._common import read_payloads
    from tools._keypaths import extract_key_paths
    from tools._registry import load_registry
    from tools._reservoir import configure_duckdb
    from tools._window import SIGNALS, resolve_window

    return (
        Counter,
        SIGNALS,
        UTC,
        configure_duckdb,
        datetime,
        duckdb,
        extract_key_paths,
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
def _(Counter, extract_key_paths, payloads):
    # Blob-level fill count: in how many export blobs each key path appears.
    fill = Counter()
    for _payload in payloads:
        for _kp in extract_key_paths(_payload):
            fill[_kp] += 1
    total_blobs = len(payloads) or 1
    return (fill, total_blobs)


@app.cell
def _(fill, load_registry, psycopg, settings, total_blobs):
    with psycopg.connect(settings.database_url) as _pg:
        registry = load_registry(_pg)

    rows = []
    for (_signal, _name, _attr), _c in fill.most_common():
        status = registry.status_of(_signal, _name, _attr) or "unclassified"
        rows.append(
            {
                "signal": _signal,
                "signal_name": _name,
                "attr_path": _attr,
                "status": status,
                "blobs": _c,
                "fill_pct": round(100 * _c / total_blobs, 1),
            }
        )
    candidates = [r for r in rows if r["status"] in ("kept", "unclassified")]
    return (candidates,)


@app.cell
def _(candidates, mo):
    mo.vstack(
        [
            mo.md(f"**{len(candidates)} candidates** (kept or unclassified) by fill rate:"),
            mo.ui.table(candidates, selection=None),
        ]
    )
    return


if __name__ == "__main__":
    app.run()
