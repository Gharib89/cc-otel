"""PROTOTYPE (#352) — baseline reservoir read cost, split into its phases.

Throwaway. Measures, per (signal, day) partition:
  fetch_bytes  network only: read_blob over the glob, summing compressed bytes
  json_read    network + gunzip + JSON->text: read_json_objects (what the lab does)
  py_decode    json.loads over the returned text
  aggregate    fill_counts + attr_value_samples (the queries the notebooks run)
"""

from __future__ import annotations

import json
import sys
import time
from datetime import date

import duckdb

sys.path.insert(0, "D:/projects/cc-otel")

from analysis._common import attr_value_samples, fill_counts, load_env  # noqa: E402
from cc_otel_sink.config import load_settings  # noqa: E402
from tools._reservoir import configure_duckdb  # noqa: E402
from tools._window import globs  # noqa: E402

DAYS = [date(2026, 7, 26), date(2026, 7, 27), date(2026, 7, 28)]
SIGNALS = ("metrics", "logs")


def timed(fn):
    t0 = time.perf_counter()
    out = fn()
    return out, time.perf_counter() - t0


def main() -> None:
    load_env()
    settings = load_settings()
    con = duckdb.connect()
    configure_duckdb(con, settings)
    container = settings.blob_container

    print(f"{'partition':32} {'blobs':>6} {'gz MB':>7} {'fetch':>7} {'json':>7} {'decode':>7} {'agg':>7}")
    totals = dict.fromkeys(("fetch", "json", "decode", "agg"), 0.0)
    for day in DAYS:
        for signal in SIGNALS:
            (target,) = globs(container, (signal,), [day])
            esc = target.replace("'", "''")

            (nblobs, nbytes), t_fetch = timed(
                lambda: con.execute(
                    f"SELECT count(*), sum(octet_length(content)) FROM read_blob('{esc}')"
                ).fetchone()
            )
            rows, t_json = timed(
                lambda: con.execute(
                    f"SELECT json FROM read_json_objects('{esc}', format='unstructured')"
                ).fetchall()
            )
            payloads, t_decode = timed(lambda: [json.loads(t) for (t,) in rows])
            _, t_agg = timed(lambda: (fill_counts(payloads), attr_value_samples(payloads)))

            print(
                f"signal={signal} dt={day} {nblobs:>6} {(nbytes or 0)/1e6:>7.2f} "
                f"{t_fetch:>7.2f} {t_json:>7.2f} {t_decode:>7.2f} {t_agg:>7.2f}"
            )
            totals["fetch"] += t_fetch
            totals["json"] += t_json
            totals["decode"] += t_decode
            totals["agg"] += t_agg
    print("TOTALS", {k: round(v, 2) for k, v in totals.items()})


if __name__ == "__main__":
    main()
