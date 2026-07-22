# Cost is promoted into the marts as API-equivalent value consumed (supersedes ADR-0002's no-cost clause)

**Status:** accepted

ADR-0002 defined schema-v2 with "no cost columns in marts," and CONTEXT.md's *Adoption report*
glossary said the report "explicitly excludes cost — subscription seats make `cost_usd`
misleading." The adopt-findings decision (#158, decision Q1; map #153) reverses that for one
carefully-scoped metric: `cost_usd` is promoted into `marts.fact_api_usage`. This ADR records
that reversal so the design sources stop contradicting the shipped schema.

## Decisions

- **`cost_usd` is API-equivalent value consumed, not spend.** ITWorx pays a flat per-seat
  subscription, so the dollar figure is never a marginal invoice line. It is reframed as *the
  value the same usage would cost at metered API pricing* — a ROI/value signal, which is what
  makes it safe to surface where raw "cost" would mislead. Columns and comments name it
  accordingly.
- **Sourced from the already-promoted raw column.** The value comes from `raw.events.cost_usd`
  on `api_request` events (promoted at ingest per the sink's write contract), surfaced through
  `staging.stg_api_request` and summed per api-usage grain. No new ingest or raw-schema change.
- **Cross-checked, never blindly trusted.** The promoted sum is reconciled against the
  independent `claude_code.cost.usage` counter each refresh; a divergence past tolerance (>1%
  relative *and* >$0.01 absolute) is recorded as a `cost_promotion_divergence` DQ finding rather
  than silently accepted.

## Consequences

- `marts.fact_api_usage` gains a `cost_usd` measure; the semantic model and report may build
  cost & ROI visuals on it (the unlocked follow-on issue).
- ADR-0002 still governs the rest of schema-v2 (no traces, fresh-start, promoted columns); only
  its no-cost-columns clause is superseded here. Production and interim both carry the column.
- The *Adoption report* glossary in CONTEXT.md is updated: cost is included as API-equivalent
  value, no longer excluded.
