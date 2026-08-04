# Revocation events exact-date a Claude closure; absence stays the removal signal

**Status:** accepted. Amends ADR-0009, whose premise ("no status column, no revocation date") and
whose *Revocation is absence* decision both need narrowing now that IS has shipped revocation
columns. Scope settled with Ahmed on 2026-08-04 (#419, follow-up to #291).

ADR-0009 predicted this: "If IS adds a status or revocation column (#291), it lands in `extra` on
the next drop with no code change, and promoting it is a column plus a derivation edit — not a
backfill." That is exactly what happened — the 2026-08-02 drop added
`revoked_subscription_1/2` and `revoke_date_1/2`, and they were already on hand in
`ref.seat_roster_snapshot.extra`.

What the prediction got wrong is the *value* of the new columns. #291's acceptance criterion
expected a confirmed revocation signal strong enough to "retire the loader's truncation guard, and
re-date seat closures from the revocation date". The delivered export falsifies that:

- The columns record **per-subscription revocation events** — which subscription, and when — not a
  person-level status. 42 of the 43 records in the first such drop are Github Copilot revocations;
  exactly one is a Claude seat (`yara.yassien`, `Claude Standard`, 8/2/2026).
- **Full removals still happen by absence.** Four people present on 2026-07-25 are simply gone from
  the 2026-08-02 drop, with no revocation record of any kind.
- **Claude tier losses are mostly unrecorded too.** Six seats moved `Standard` -> `Github Copilot`;
  only `yara.yassien` carries a matching revoked-Claude record.

So the export is still a current-state snapshot that under-reports removals. It just also carries,
for a minority of cases, a date the derivation previously had to guess.

## Decisions

- **The columns are promoted, at assignment grain.** `revoked_subscription_raw` and `revoke_date`
  on `ref.seat_roster_snapshot`, unpivoted per sequence exactly like `subscription_N` /
  `assignment_date_N` — they describe one subscription, not one person. Nullable, no backfill:
  snapshots are immutable (ADR-0009), so drops already landed keep their `extra` copy and read NULL.
- **`revoked_subscription_raw` is not normalized, and gets no `revoked_seat_tier` counterpart.**
  `normalize_tier` strips the `Claude ` prefix and passes every other product through verbatim, so a
  normalized tier cannot say which product it came from — and telling a revoked Claude subscription
  from a revoked Copilot one is the entire question here.
- **The truncation guards and closure-by-absence stay exactly as they were.** #291's plan to retire
  them is withdrawn, not deferred: the export demonstrably does not record all removals, so absence
  remains the primary revocation signal and a seat vanishing from a drop still closes at that
  drop's as-of date.
- **A revoke date exact-dates a closure only under three conditions,** all evaluated on one
  person's rows within one drop: some `revoked_subscription_raw` is a Claude subscription; **no**
  `subscription_raw` is (the person holds no Claude subscription any more); and the interval being
  closed was itself a Claude seat. Everything else is inert — a Copilot revocation is not a seat
  event, and a revoked Claude tier alongside a still-held one is a tier change the interval logic
  already dates correctly.
- **The third condition is ours, not IS's.** `Github Copilot` is stored as a `seat_tier` today, so
  without it a Claude revocation could exact-date the close of a non-Claude interval. It only ever
  narrows the exact-dating.
- **The revoke-dated close is clamped to the next interval's start.** `marts.fact_seat_day` is
  uniquely indexed on `(date_day, user_email)`, so an overlap would fail its refresh outright
  rather than merely misreport. A revoke date landing after the next interval already opened keeps
  the old observation-dated close.

## Considered options

- **Re-date every closure from the revocation columns** (#291's plan). Rejected on the data: most
  removals carry no revocation record, so this would leave those seats open indefinitely.
- **Treat a Claude revocation as a closure regardless of what the person still holds.** Simpler
  predicate. Rejected: it closes the seat of anyone moving between two Claude tiers, where the old
  tier's revocation is recorded alongside the new tier — a tier change misread as a revocation.
- **A `valid_to_basis` column mirroring `valid_from_basis`.** Would make the revoke-dated share of
  closures measurable the way the boundary-basis finding does for openings. Deferred, not rejected —
  one Claude revocation exists in the whole population, so the measure has nothing to measure yet.

## Consequences

- **A person's intervals may now have a gap.** A Claude seat revoked on the 28th, on someone who
  still appears in the next drop holding Copilot, leaves them seatless in between — which is the
  truth, and what an observation-dated close could not express. This narrows ADR-0009's and
  CONTEXT.md's "a tier change closes one interval exactly where the next opens": that still holds
  between two Claude tiers, so no seat-day is ever counted twice, but contiguity across a person's
  whole timeline is no longer guaranteed.
- The exact-dating applies to roughly one seat in the current population. It is worth having anyway
  because it costs a predicate, and because IS's export behaviour may widen: if revocation records
  start covering removals, the same rule silently starts producing more exact dates.
- `dq_finding`'s `seat_boundary_basis` gauge still measures openings only, so the reported
  observation-dated share does not move. The closures it cannot see remain invisible to it — the
  deferred `valid_to_basis` column above is what would change that.
- A revoke date is not validated against the drop's as-of date the way an assignment date is
  (`impossible_as_of`). A revocation dated after the export reporting it would be clamped by the
  interval logic rather than refused at load. Accepted: no such row exists, and the clamp is
  already load-bearing for the overlap case.
