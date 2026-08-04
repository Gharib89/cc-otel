# A seat interval records the basis for its close, not just its opening

**Status:** accepted. Settles the `valid_to_basis` option ADR-0024 deferred, and completes the
"inferred share of the timeline is measurable" consequence ADR-0009 claimed. Scope settled with
Ahmed on 2026-08-04 (#421, parent #290).

ADR-0009 promised that "every derived interval carries a `valid_from_basis` marker (#293) so the
inferred share of the timeline is measurable". That was only half true: the marker described
openings, and the `seat_boundary_basis` dq gauge reports the observation-dated share of openings.
Closings had no counterpart at all, even though ADR-0024 gave them three genuinely different
provenances — an exact revoke date, a successor interval's opening, and a drop the seat simply
vanished from. A consumer could not tell a closure IS dated to the day from one inferred to within
a week.

ADR-0024 deferred the column because "one Claude revocation exists in the whole population — the
measure has nothing to measure yet". That reasoning is now known to be *too optimistic*: the
promoted `revoked_subscription_raw` / `revoke_date` columns take no backfill (ADR-0009
immutability), and `roster_load` refuses byte-identical content with no `--force` override, so the
2026-08-02 drop's single Claude revocation can never reach them. Until IS sends a further drop the
exact-dated share of closures is **zero**, not one.

The column is added anyway, on ADR-0024's own reasoning for the predicate it measures: it costs a
CASE arm, and it starts reporting the moment IS's export behaviour widens.

## Decisions

- **`valid_to_basis` on `staging.stg_seat_interval` and `marts.dim_seat`,** with three values and
  a meaningful NULL:

  | Value | The close came from | Confidence |
  |---|---|---|
  | `revoke-dated` | IS's revoke date, under ADR-0024's three-condition rule | exact |
  | `succession-dated` | the person's next interval's `valid_from` — a tier or organization change | that opening's own basis |
  | `observation-dated` | the as-of of the first drop the seat was absent from | inferred, ~1 week (ADR-0009) |
  | `NULL` | the interval is still open | not applicable |

  NULL means *open*, never *unknown* — every closed interval has a basis.
- **The vocabulary reuses `observation-dated` and diverges elsewhere.** `observation-dated` means
  the same thing on both halves, so it keeps its name. There is deliberately no `source-dated` on
  the closing side: IS supplies an assignment date for openings and a revoke date for closings, and
  conflating them under one word would hide that only the latter is governed by ADR-0024's
  three conditions. `succession-dated` has no opening counterpart at all.
- **`valid_to` is derived *from* `valid_to_basis`, not alongside it.** ADR-0024's overlap clamp was
  a `LEAST()`; it becomes a branch in a single ordered predicate chain, and the date is then
  selected by the verdict. This is the same discipline `is_source_dated` already applies on the
  opening side — one predicate, because the boundary date and the basis recorded for it must never
  disagree. A revoke date landing after the successor opened yields that opening, and is therefore
  reported as `succession-dated`, not `revoke-dated`.
- **`dim_seat_current` does not get the column.** It holds only open intervals, where the basis is
  NULL on every row by construction.
- **The `seat_boundary_basis` dq gauge is left measuring openings only.** Whether a second gauge
  earns its own append-only `dq_finding` row is a separate decision, tracked separately — it is not
  implied by having the column.

## Considered options

- **A `dq_finding` gauge instead of a column** (#421's narrower framing). Rejected as the primary
  move: a gauge reports one fleet-wide share, while the column lets a consumer filter or attribute
  any seat-level measure by closing confidence. The gauge remains available on top of the column;
  the reverse is not true.
- **Reusing `source-dated` for the revoke case,** for symmetry with `valid_from_basis`. Rejected —
  see the vocabulary decision above.
- **Waiting for the re-entry condition** (more than one Claude revocation in the population).
  Rejected once it emerged the condition is unreachable for the current drop: waiting would have
  meant waiting on IS, indefinitely, for a column that costs one CASE arm.

## Consequences

- **`marts.dim_seat` gains a column, and the report is owned outside this repo (ADR-0022).** The
  semantic model's partitions are `SELECT *`, so the column arrives in the owner's model on the
  next refresh whether or not it is used. It is additive — no rename, no type change — so nothing
  in the published report breaks; the owner is told it exists rather than asked to act.
- **The column reports no `revoke-dated` rows until IS sends a drop after 2026-08-02.** Everything
  closed to date is `succession-dated` or `observation-dated`. That is the honest state, and it is
  itself the measure ADR-0009 asked for.
- **`stg_seat_interval` appends the column last.** `CREATE OR REPLACE VIEW` can only add trailing
  columns, so the staging view's column order no longer groups the two basis markers together;
  `dim_seat`, rebuilt outright, does group them. The rollback has to `DROP ... CASCADE` and
  recreate the three seat marts and `stg_seat_uncovered_day`, because removing a view column is the
  one edit `CREATE OR REPLACE` cannot make.
- ADR-0009's "the inferred share of the timeline is measurable" now holds for the whole timeline
  rather than its opening half.
