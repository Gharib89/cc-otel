# Blob raw-reservoir alongside Postgres (redacted-raw)

**Status:** accepted

We add an **Azure Blob Storage** container as a redacted-raw OTLP reservoir next to the Postgres sink. Goal: keep Postgres holding only the flattened columns the adoption report reads, while preserving the raw payloads so we can discover unpromoted keys / replay a future parser without re-instrumenting the fleet. Postgres stays the source of truth for the report; blob is an archive + discovery/replay store, queried on demand with **DuckDB** (SQL over JSON files, zero standing compute).

## Decisions

- **Content = redacted-raw.** The full OTLP body is written with the secret-bearing fields stripped (`full_command`, `bash_command`, `file_path`, `error`, and the whole `tool_parameters` / `tool_input` tool-argument payloads) — the redaction logic proven in the POC's `redact.py`, carried into the production sink. Every other key — including all named enums and unknown keys — stays raw, so key-discovery is intact.
- **Layout.** One gzipped file per collector batch, single container `raw`, Hive partitioning `signal=<metrics|logs>/dt=<YYYY-MM-DD>/` so DuckDB prunes by signal + date (no traces partition — traces are off at the source, ADR-0001).
- **Writer = sink-side, best-effort.** FastAPI `BackgroundTasks` writes after the 200 response; a blob failure logs a warning and never fails ingest. Keeps the reservoir fully isolated from the source-of-truth path.
- **Tier/redundancy/retention.** Hot, LRS, keep-forever (no lifecycle). Storage is ~$1–2/mo at this volume, so tiering to Cool/Cold isn't worth the 128 KiB minimum-object floor, retrieval fees, and early-deletion penalties.
- **Auth.** ACA system-assigned managed identity + `Storage Blob Data Contributor`. No keys or connection strings.
- **Tuning.** Bump collector `batch.timeout` 5s → 60s → ~12× fewer/larger files (better DuckDB scans, cheaper writes); costs only ~1 min of extra latency into Postgres, irrelevant for a daily-refresh report.

## Considered options

- **Native collector `azureblobexporter` (config-only, zero code).** Rejected as the main line: **alpha** for all signals, and its `retry_on_failure`-without-queue design can back-pressure the *shared* pipeline that feeds Postgres. May be A/B-tested in the POC RG later — cost and storage layout are identical, so the writer choice is deferrable.
- **True byte-for-byte raw.** Rejected without a security sign-off: `OTEL_LOG_TOOL_DETAILS=1` is deployed, so raw logs carry developers' command lines and file paths — a keep-forever PII lake for 200 real users.
- **Fix at the source (`OTEL_LOG_TOOL_DETAILS=0`).** Rejected: the flag is all-or-nothing — turning it off also downgrades `skill_name` / `plugin_name` / `command_name` to generics, which guts the adoption report. Redaction must therefore happen downstream.
- **Query via Synapse serverless / Fabric.** Rejected for now: DuckDB meets "occasionally check the raw" at zero standing cost; revisit if exploration graduates to a standing report.

## Consequences

- Once blob is flowing, `attrs` / `resource` JSONB can be dropped (or trimmed) from Postgres → leaner DB, slower storage growth. Separate task.
- **Carried-over POC finding:** in the POC, redaction ran only on the (now disabled) spans path, so with `OTEL_LOG_TOOL_DETAILS=1` `tool_parameters` (command lines + paths) landed **unredacted in Postgres `events.attrs`**. The production sink must apply the same downstream redaction on the Postgres write path — covered by the PII redaction policy design.
- Sizing/cost impact recorded in the POC's `docs/azure-production-sizing.md` §2 (archived).
