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
        key path this shows its fill rate (share of export blobs carrying it), value
        cardinality, and example values — the stats curation needs to size a column.
        Value stats are pooled per attribute key (across signals). High-fill kept keys
        are the strongest promotion candidates.

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

    from datetime import UTC, datetime

    import duckdb
    import psycopg
    from cc_otel_sink.config import load_settings

    from analysis._common import attr_value_samples, fill_counts, read_payloads
    from tools._registry import load_registry
    from tools._reservoir import configure_duckdb
    from tools._window import SIGNALS, resolve_window

    return (
        SIGNALS,
        UTC,
        attr_value_samples,
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
    try:
        configure_duckdb(con, settings)
        payloads = read_payloads(con, settings.blob_container, SIGNALS, days)
    finally:
        con.close()
    return (payloads,)


@app.cell
def _(attr_value_samples, fill_counts, payloads):
    fill = fill_counts(payloads)  # blob-level: how many payloads carry each key path
    values = attr_value_samples(payloads)  # attr key -> value Counter (cardinality/examples)
    total_blobs = len(payloads) or 1
    return (fill, total_blobs, values)


@app.cell
def _(fill, load_registry, psycopg, settings, total_blobs, values):
    with psycopg.connect(settings.database_url) as _pg:
        registry = load_registry(_pg)

    rows = []
    for (_signal, _name, _attr), _c in fill.most_common():
        status = registry.status_of(_signal, _name, _attr) or "unclassified"
        _vals = values.get(_attr)
        rows.append(
            {
                "signal": _signal,
                "signal_name": _name,
                "attr_path": _attr,
                "status": status,
                "blobs": _c,
                "fill_pct": round(100 * _c / total_blobs, 1),
                "cardinality": len(_vals) if _vals else 0,
                "examples": ", ".join(v for v, _ in _vals.most_common(3)) if _vals else "",
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
