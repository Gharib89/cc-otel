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
        # Ecosystem exploration (starter)

        Open-ended attribute explorer over the reservoir: pick any attribute key
        discovered in the window and see its top values. Seeds the charter questions
        — top skills used, custom-skill authors — once you pick the attribute key
        that carries them. Extend with focused cells as the schema settles; keep the
        starter generic rather than hard-coding key names that may drift.
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
    from cc_otel_sink.config import load_settings

    from analysis._common import iter_attrs, load_env, read_payloads, scalar
    from tools._reservoir import configure_duckdb
    from tools._window import resolve_window
    from tools.signals import ROUTES

    # No shell sourced the env file into this kernel — load it before the cell
    # below builds Settings (`CC_OTEL_ENV_FILE` picks a file other than .env.interim).
    load_env()

    return (
        Counter,
        ROUTES,
        UTC,
        configure_duckdb,
        datetime,
        duckdb,
        iter_attrs,
        load_settings,
        read_payloads,
        resolve_window,
        scalar,
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
def _(ROUTES, configure_duckdb, days, duckdb, read_payloads, settings):
    con = duckdb.connect()
    try:
        configure_duckdb(con, settings)
        payloads = read_payloads(
            con, settings.blob_container, ROUTES, days, settings.blob_compacted_container
        )
    finally:
        con.close()
    return (payloads,)


@app.cell
def _(iter_attrs, mo, payloads):
    attr_keys = sorted({_k for _p in payloads for (_k, _v) in iter_attrs(_p)})
    picker = mo.ui.dropdown(options=attr_keys, label="attribute key")
    mo.vstack([mo.md(f"**{len(attr_keys)} distinct attribute keys** in the window:"), picker])
    return (picker,)


@app.cell
def _(Counter, iter_attrs, mo, payloads, picker, scalar):
    _key = picker.value
    if _key:
        _values = Counter(
            scalar(_v) for _p in payloads for (_k, _v) in iter_attrs(_p) if _k == _key
        )
        out = mo.ui.table(
            [{"value": _val, "count": _n} for _val, _n in _values.most_common(50)],
            selection=None,
        )
    else:
        out = mo.md("Pick an attribute key above to see its top values.")
    mo.vstack([out])
    return


if __name__ == "__main__":
    app.run()
