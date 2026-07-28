"""PROTOTYPE (#352) — split the per-partition read cost into network vs local decode.

Throwaway. For one (signal, day) partition:
  azure_read   read_json_objects over azure:// (what the lab pays today)
  download     the same blobs pulled with the blob SDK, 16 threads
  local_read   read_json_objects over the downloaded copies (zero network)
"""

from __future__ import annotations

import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import date
from pathlib import Path

import duckdb

sys.path.insert(0, "D:/projects/cc-otel")

from analysis._common import load_env  # noqa: E402
from cc_otel_sink.config import load_settings  # noqa: E402
from tools._reservoir import configure_duckdb  # noqa: E402
from tools._window import globs, partition_prefix  # noqa: E402

SIGNAL, DAY = "logs", date(2026, 7, 26)
LOCAL = Path(
    "C:/Users/AHMED~1.GHA/AppData/Local/Temp/claude/D--projects-cc-otel/"
    "f92d384e-3738-41fa-9147-675af5e3a7b9/scratchpad/local_blobs"
)


def timed(fn):
    t0 = time.perf_counter()
    out = fn()
    return out, time.perf_counter() - t0


def main() -> None:
    load_env()
    settings = load_settings()
    con = duckdb.connect()
    configure_duckdb(con, settings)

    (target,) = globs(settings.blob_container, (SIGNAL,), [DAY])
    rows, t_azure = timed(
        lambda: con.execute(
            f"SELECT json FROM read_json_objects('{target}', format='unstructured')"
        ).fetchall()
    )
    print(f"azure_read  {len(rows):>6} payloads {t_azure:>7.2f}s")

    from azure.identity import DefaultAzureCredential
    from azure.storage.blob import BlobServiceClient

    LOCAL.mkdir(parents=True, exist_ok=True)
    svc = BlobServiceClient(settings.blob_account_url, credential=DefaultAzureCredential())
    cc = svc.get_container_client(settings.blob_container)
    names = [b.name for b in cc.list_blobs(name_starts_with=partition_prefix(SIGNAL, DAY))]

    def pull(name: str) -> int:
        data = cc.download_blob(name).readall()
        (LOCAL / name.replace("/", "_")).write_bytes(data)
        return len(data)

    sizes, t_download = timed(lambda: list(ThreadPoolExecutor(16).map(pull, names)))
    print(f"download    {len(names):>6} blobs    {t_download:>7.2f}s  {sum(sizes)/1e6:.2f} MB gz")

    local_glob = (LOCAL / "*.json.gz").as_posix()
    rows2, t_local = timed(
        lambda: con.execute(
            f"SELECT json FROM read_json_objects('{local_glob}', format='unstructured')"
        ).fetchall()
    )
    print(f"local_read  {len(rows2):>6} payloads {t_local:>7.2f}s")


if __name__ == "__main__":
    main()
