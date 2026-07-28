"""PROTOTYPE (#352) — build two compacted layouts, upload them, measure the read delta.

Throwaway. Strictly additive: writes to its own container (COMPACT_CONTAINER), never
to `raw`. Layouts:

  B  payload-string parquet   one file per (signal, day), column `json` = the whole
                              OTLP payload text. Schema-stable by construction; the
                              notebooks keep their python aggregation.
  C  record-grain parquet     one file per (signal, day), long format
                              (payload_id, signal, signal_name, attr_key, attr_value,
                              session_id, seat) — aggregation becomes SQL.

Usage: bench_compact.py build | read | drop
"""

from __future__ import annotations

import csv
import json
import sys
import time
from datetime import date
from pathlib import Path

import duckdb

sys.path.insert(0, "D:/projects/cc-otel")

from analysis._common import attr_value_samples, fill_counts, iter_records, load_env  # noqa: E402
from cc_otel_sink.config import load_settings  # noqa: E402
from tools._reservoir import configure_duckdb  # noqa: E402
from tools._window import globs  # noqa: E402

DAYS = [date(2026, 7, 26), date(2026, 7, 27), date(2026, 7, 28)]
SIGNALS = ("metrics", "logs")
COMPACT_CONTAINER = "compaction-proto"
OUT = Path(
    "C:/Users/AHMED~1.GHA/AppData/Local/Temp/claude/D--projects-cc-otel/"
    "f92d384e-3738-41fa-9147-675af5e3a7b9/scratchpad/compact"
)


def timed(fn):
    t0 = time.perf_counter()
    out = fn()
    return out, time.perf_counter() - t0


def connect():
    load_env()
    settings = load_settings()
    con = duckdb.connect()
    configure_duckdb(con, settings)
    return con, settings


def blob_service():
    from azure.identity import DefaultAzureCredential
    from azure.storage.blob import BlobServiceClient

    load_env()
    settings = load_settings()
    return BlobServiceClient(settings.blob_account_url, credential=DefaultAzureCredential())


def build() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    con, settings = connect()
    svc = blob_service()
    try:
        svc.create_container(COMPACT_CONTAINER)
    except Exception as err:  # already exists
        print("container:", type(err).__name__)
    cc = svc.get_container_client(COMPACT_CONTAINER)

    for day in DAYS:
        for signal in SIGNALS:
            (target,) = globs(settings.blob_container, (signal,), [day])
            esc = target.replace("'", "''")
            stem = f"signal={signal}/dt={day:%Y-%m-%d}"

            # Layout B — payload strings straight out of the JSON reader.
            b_path = OUT / f"B_{signal}_{day:%Y%m%d}.parquet"
            _, t_b = timed(
                lambda: con.execute(
                    f"COPY (SELECT json FROM read_json_objects('{esc}', format='unstructured')) "
                    f"TO '{b_path.as_posix()}' (FORMAT parquet, COMPRESSION zstd)"
                )
            )

            # Layout C — record grain, from the payloads we now have locally in B.
            # Rows are staged through a CSV: DuckDB's executemany is row-at-a-time and
            # takes minutes on a single day's records, `COPY ... FROM csv` seconds.
            def build_c() -> int:
                texts = con.execute(
                    f"SELECT json FROM read_parquet('{b_path.as_posix()}')"
                ).fetchall()
                staged = OUT / f"C_{signal}_{day:%Y%m%d}.csv"
                nrows = 0
                with staged.open("w", newline="", encoding="utf-8") as fh:
                    writer = csv.writer(fh)
                    writer.writerow(
                        [
                            "payload_id",
                            "signal",
                            "signal_name",
                            "attr_key",
                            "attr_value",
                            "session_id",
                            "seat",
                        ]
                    )
                    for payload_id, (text,) in enumerate(texts):
                        payload = json.loads(text)
                        for sig, name, attrs in iter_records(payload):
                            session = attrs.get("session.id", "")
                            seat = attrs.get("user.email", "").strip().lower()
                            for key, value in attrs.items():
                                writer.writerow(
                                    [payload_id, sig, name, key, value, session, seat]
                                )
                                nrows += 1
                con.execute(
                    f"COPY (SELECT * FROM read_csv('{staged.as_posix()}', header=true, "
                    "quote='\"', escape='\"', "
                    "columns={'payload_id': 'BIGINT', 'signal': 'VARCHAR', "
                    "'signal_name': 'VARCHAR', 'attr_key': 'VARCHAR', "
                    "'attr_value': 'VARCHAR', 'session_id': 'VARCHAR', 'seat': 'VARCHAR'})) "
                    f"TO '{(OUT / f'C_{signal}_{day:%Y%m%d}.parquet').as_posix()}' "
                    "(FORMAT parquet, COMPRESSION zstd)"
                )
                return nrows

            nrows, t_c = timed(build_c)

            for layout in ("B", "C"):
                local = OUT / f"{layout}_{signal}_{day:%Y%m%d}.parquet"
                with local.open("rb") as fh:
                    cc.upload_blob(f"{layout}/{stem}/part-0.parquet", fh, overwrite=True)
                print(
                    f"{layout} signal={signal} dt={day} {local.stat().st_size/1e6:>6.2f} MB "
                    f"build {(t_b if layout == 'B' else t_c):>6.2f}s"
                    + (f" rows={nrows}" if layout == "C" else "")
                )


def read() -> None:
    con, _ = connect()
    print(f"{'path':34} {'fetch':>7} {'decode':>7} {'agg':>7}")
    for day in DAYS:
        for signal in SIGNALS:
            stem = f"signal={signal}/dt={day:%Y-%m-%d}"

            b_glob = f"azure://{COMPACT_CONTAINER}/B/{stem}/*.parquet"
            rows, t_fetch = timed(
                lambda: con.execute(f"SELECT json FROM read_parquet('{b_glob}')").fetchall()
            )
            payloads, t_decode = timed(lambda: [json.loads(t) for (t,) in rows])
            _, t_agg = timed(lambda: (fill_counts(payloads), attr_value_samples(payloads)))
            print(f"B {signal:8} {day} {t_fetch:>7.2f} {t_decode:>7.2f} {t_agg:>7.2f}")

            c_glob = f"azure://{COMPACT_CONTAINER}/C/{stem}/*.parquet"
            # Same two answers as fill_counts + attr_value_samples, in SQL.
            _, t_c = timed(
                lambda: (
                    con.execute(
                        "SELECT signal, signal_name, attr_key, count(DISTINCT payload_id) blobs, "
                        "count(*) records, count(DISTINCT session_id) sessions, "
                        "count(DISTINCT seat) seats "
                        f"FROM read_parquet('{c_glob}') GROUP BY 1,2,3"
                    ).fetchall(),
                    con.execute(
                        "SELECT attr_key, attr_value, count(*) n "
                        f"FROM read_parquet('{c_glob}') GROUP BY 1,2"
                    ).fetchall(),
                )
            )
            print(f"C {signal:8} {day} {t_c:>7.2f} {'-':>7} {'(in SQL)':>7}")


def drop() -> None:
    svc = blob_service()
    svc.delete_container(COMPACT_CONTAINER)
    print(f"deleted container {COMPACT_CONTAINER}")


if __name__ == "__main__":
    {"build": build, "read": read, "drop": drop}[sys.argv[1]]()
