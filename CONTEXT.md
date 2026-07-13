# Claude Code Telemetry (cc-otel)

Captures Claude Code developer-usage telemetry from ITWorx developer machines into Postgres for a daily-refresh Power BI adoption report. One context: ingest → store → report.

## Language

### Signals

**Official telemetry**:
Metrics and events (logs) emitted natively by Claude Code's built-in OTel exporter (including the enhanced-telemetry beta). Covers tokens, LOC, commits, PRs, active time, model, effort, skills, MCPs, subagents, hooks, plugins. Traces are disabled in production (killed for volume; agent hierarchy forfeited — ADR-0001).
_Avoid_: native telemetry, CC OTel

**Wrapper telemetry**:
Gauges emitted by the statusline wrapper — only what official telemetry cannot provide: rate-limit utilization and reset countdown per window, labelled `user.email`, `session.id`, `window`. See ADR-0003.
_Avoid_: statusline metrics

**Rate-limit window**:
An Anthropic subscription quota period — `5h` or `7d` (plus model-scoped variants like `7d_sonnet`). Utilization is the Anthropic-computed used-percentage (0–100).
_Avoid_: quota, budget

**Pace**:
Utilization divided by elapsed fraction of the window — >1 means on track to exhaust the window before it resets. Basis of `projected_eow_pct`.

### Pipeline

**Wrapper**:
`cc-otel-wrapper.mjs` — sits in front of the user's real statusline command, forwards the statusline JSON unchanged, and pushes wrapper telemetry as a side effect.
_Avoid_: statusline script

**Collector**:
The OpenTelemetry Collector container — the only authenticated ingest boundary (bearer token); converts OTLP/protobuf → OTLP/JSON for the sink.

**Sink**:
Our FastAPI service that parses OTLP/JSON and writes rows to Postgres. Trusts the collector; never exposed externally.

**Adoption report**:
The slim daily-refresh Power BI report (successor to the POC report). Focus: productivity + adoption (tokens out, LOC, commits, PRs, active time, sessions, limits, model/effort mix, top skills/MCPs/subagents). Explicitly excludes cost — subscription seats make `cost_usd` misleading.
_Avoid_: dashboard v2, current report

**Non-empty session**:
A session with at least one `user_prompt` event — a human actually typed something. Sessions without one (statusline-only launches, `/resume` browsing) are empty and excluded from session counts and duration averages.
_Avoid_: active session (that means something else — see `active_session_count`)

**Session duration**:
Wall clock: `last_seen_at − started_at` of a non-empty session. Distinct from **active time**, which is `active_time.total` (excludes idle) and feeds "avg active time per day".

### Data model

**Mart**:
A materialized view in the `marts` schema — the conformed star schema (dimensions, facts, bridges) the adoption report reads. Refreshed hourly by `pg_cron` inside Postgres via `marts.refresh_all()` before the Power BI refresh, each cycle logged to `mart_refresh_log`. Raw tables are archive + drill source.
_Avoid_: aggregate table, summary view

**Raw reservoir**:
An Azure Blob Storage container (`raw`) holding the **redacted-raw** OTLP payloads — the full body with only secret-bearing fields stripped (`full_command`, `bash_command`, `file_path`, `error`), everything else kept verbatim. Purpose: keep Postgres lean while preserving raw for **drift** discovery and future-parser replay. Not the source of truth (the report reads Postgres marts); queried ad-hoc with DuckDB. See ADR-0005.
_Avoid_: raw dump, blob backup

**Column registry**:
`meta.column_registry` — the curated catalogue of every promoted column and known `attrs` key: type, description, what it's useful for, status. Source of truth for the generated data dictionary.

**Drift**:
An `attrs`/`resource` key observed in the raw reservoir but absent from the column registry — the signal that Anthropic added new telemetry. Surfaced on demand by prepared DuckDB queries (`tools/`) over the reservoir; analysis is manual. Postgres cannot detect it — schema-v2 drops the JSONB there.

### Deployment

**Tracked machine**:
A developer machine with Claude Code telemetry configured (managed settings + wrapper). The scale unit for infra sizing, token distribution, and fleet config. Distinct from developer — one dev may have several tracked machines; reporting keys on `user.email`.
_Avoid_: seat, endpoint

**Installer**:
`install.ps1` — the idempotent, **drift-repairing** per-machine setup script. Each tick it verifies real state (installed files, machine-scope env vars, statusline wiring, user-settings telemetry keys) and repairs any drift; a clean machine no-ops fast. It **checks** for Node.js but never installs it (the LTS MSI is an IS prerequisite, issue #31) — statusline wiring self-heals once Node is present. IS pushes it fleet-wide via their managed tool on a 90-minute cadence; the distribution mechanism itself is out of our scope, the script is ours. `build-installer.ps1` bakes the collector endpoint + fleet token into the managed settings and **stamps** the artifact (`SHA256(wrapper + managed-settings + schema version)`), so a rotated token forces every machine to re-converge.
_Avoid_: deployment script, rollout tool

**Parallel cutover**:
The POC Azure env stays live as fallback until the adoption report completes its first successful Power BI refresh from the **production** Azure Postgres; only then is the POC decommissioned. See ADR-0004.

**Azure prod stack**:
The production environment: a second Azure resource group — IS-provisioned but empty, in an ITWorx subscription — holding a Postgres Flexible Server (public endpoint) plus an Azure Container Apps environment running the collector + sink in one Container App. IS grants RG Contributor only; Ahmed deploys all of it, Postgres included, via Bicep (ADR-0004).
