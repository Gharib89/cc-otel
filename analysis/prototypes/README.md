# PROTOTYPE — reservoir read cost + Parquet compaction (#352)

Throwaway. This branch exists only as the primary source behind the answer on
[#352](https://github.com/Gharib89/cc-otel/issues/352); it is never merged to `main`.

The scripts hardcode absolute scratchpad paths and a 3-day window (Jul 26-28, 2026), and
`bench_compact.py` writes to its own `compaction-proto` container — never to `raw`, so the
replay source of truth (ADR-0005) is untouched. The container was deleted after the
measurement; re-running `build` recreates it.

```sh
uv run --group analysis python -u analysis/prototypes/PROTOTYPE_352_bench_baseline.py
uv run --group analysis python -u analysis/prototypes/PROTOTYPE_352_bench_compact.py build
uv run --group analysis python -u analysis/prototypes/PROTOTYPE_352_bench_compact.py read
uv run --group analysis python -u analysis/prototypes/PROTOTYPE_352_bench_compact.py drop
uv run --group analysis python -u analysis/prototypes/PROTOTYPE_352_bench_split.py
```

| script | what it measures |
|---|---|
| `bench_baseline.py` | today's per-partition cost, split into fetch / `read_json_objects` / `json.loads` / aggregate. Its `fetch` column is a **bad probe** — DuckDB's `read_blob` reads serially, so 154 s says "read_blob is slow", not "the network is slow". Read the `json` column as the live cost. |
| `bench_compact.py` | builds layout B (one parquet per signal-day, `json VARCHAR` = the payload text) and layout C (record-grain long format), uploads both, then measures the read delta from Azure on the queries the notebooks run. |
| `bench_split.py` | the diagnosis: the same partition read from Azure, downloaded with 16 threads, then re-read from local disk. Local-with-zero-network is still 9.6 s for 860 files, which is what proves the cost is per-file overhead rather than bytes. |

Verdict (full detail on #352): file **count** is the cost driver, not bytes. Layout B wins;
layout C as written drops metric values and timestamps and would duplicate `raw.*` at record
grain, so it was not chosen.
