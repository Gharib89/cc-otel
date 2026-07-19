# Interim Postgres is backfilled with mapped POC pilot data (supersedes ADR-0002 for interim)

**Status:** accepted

ADR-0002 rejected backfilling the ~6 weeks of POC pilot data into production. That decision
stands for **production**, which still starts on a fresh schema-v2. This ADR carves out the
**interim** environment: interim is backfilled with the POC `otel` `metrics`/`events` history,
mapped into schema-v2 as the current sink would write it.

## Decisions

- **Interim is backfilled; production is not.** Two of ADR-0002's premises do not hold for
  interim: (1) the rejection rested on the pilot being statistically irrelevant against a
  150–200-dev rollout, but interim today has ~7 users and ~5 days of live data, so pilot
  history is the only dataset large enough to build and demo the report against; (2) the
  old→new translation-bug risk is small — POC schema-v1 proved to be a near-superset of v2,
  so the mapping is a column rename plus a few `attrs->>` derivations, not a divergent-schema
  translation.
- **Scoped to clean Claude Code telemetry.** The backfill starts at `2026-05-24` (first clean
  all-`sum_delta` day), excludes leaked `github.copilot` metrics, and excludes the
  trace-synthesized `com.anthropic.claude_code.tracing` events (ADR-0001).
- **Indistinguishable from live.** Rows are mapped to the exact schema-v2 shape the sink
  writes, so every existing staging view, mart, and DQ rule works unchanged.
- **Deduped, idempotent, reversible.** Deduplicated against live interim sessions (drops the
  cutover sessions that dual-sent); a `meta.processed_batches` sentinel makes re-runs no-op;
  rollback is a documented date/session `DELETE` predicate needing no `raw` schema change.
- **Non-empty session redefined.** A small shared follow-on ships with the backfill: the
  non-empty-session signal moves from the `user_prompt` event to `DISTINCT prompt_id`, because
  older Claude Code builds almost never emitted `user_prompt` (42 rows in six weeks) while
  `prompt_id` is carried broadly. This is the durable turn signal for both history and live,
  and applies in production too.

## Consequences

- Interim carries mapped pilot history indistinguishable from live rows; the report renders
  `2026-05-24` → today.
- Production is unaffected and still starts fresh per ADR-0002.
- When the POC stack is decommissioned after cutover, the interim copy is the last surviving
  record of pilot history (ADR-0002's "pilot history is permanently gone" no longer holds for
  interim).
- Prompt text and other PII are not recovered — the backfill carries only the promoted columns
  the sink writes; no `attrs`/`resource` JSONB (ADR-0005 keeps unpromoted keys in the blob
  reservoir, which this backfill does not touch).
