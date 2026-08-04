# The ingest repoint: interim's sink becomes production's second front door

**Status:** accepted — **amends ADR-0020**, which assumes every seat reaches production by flipping
its own machine. Implemented by #410 (the repoint) and #409 (the terminal sweep). Decided
2026-08-03.

ADR-0020 bounds the interim→production copy by a **flip watermark**: `MIN(<event time>)` over a
seat's production rows. A seat with no production row has no watermark, so `tools.cutover_copy`
skips it — deliberately, and ADR-0020 accepts the consequence ("seats that never flip keep their
rows in interim", backstopped by #248 Part B's `pg_dump`).

Measured 2026-08-03 after #245's first run, that acceptance turned out to be expensive: **91,769
metrics rows across 15 seats** and **103,355 events rows across 16 seats** sat in interim on those
grounds, of which one seat — `hadeel.sharaf`, 46,730 metrics / 70,594 events — was **51% / 68% of
the whole**. The rows survive in the archive; the report does not show them. And the number grows
every day an unflipped seat keeps working, because it keeps writing into an environment scheduled
for deletion.

The fix is not a better copy. It is to stop interim from being a destination.

> **Measurement correction, 2026-08-04 (#415).** The two figures above count each seat's *interim
> rows above the floor*, not what production lacks, so they are not the unflipped population.
> Measured after the repoint: eleven seats have no production row at all and hold **29,110 metrics
> / 23,471 events** between them, while `hadeel.sharaf` has had a flip watermark since 2026-07-18
> and is short **654 metrics / 799 events** — 1% of the volume attributed to her, not 51% / 68% of
> the whole. The decision below is unaffected: the seats the repoint exists to reach are those
> eleven, and the largest of them holding 7,165 rows idle at decommission is the same trade. What
> the wrong figure hid is that the *copy* had already worked for every flipped seat — which is why
> #415 landed a detector rather than a new copy path. See the last consequence.

## Decisions

- **Interim's sink is repointed at production's database and reservoir.** `DATABASE_URL` →
  production `cc_otel_ingest`, `CC_OTEL_BLOB_ACCOUNT_URL` → the production storage account. Both are
  plain sink settings (`sink/src/cc_otel_sink/config.py`), so this is an Azure Container Apps
  env/secret change with **no code change and no fleet change**: interim's collector keeps its
  endpoint and its bearer token, so an unflipped machine needs nothing done to it and does not have
  to be reachable. Its telemetry simply lands in production.

  This is what ADR-0020's "dual-write during the parallel run" option was rejected for being — a
  fleet-side change on a 90-minute IS cadence. Repointing one Container App is not that: it is one
  operator action against infrastructure we already own, and it is unwound by reverting the same two
  settings.

- **An unflipped-but-alive seat then needs no new mechanism at all.** Once it writes to production
  it *has* a flip watermark — approximately the repoint moment — so the existing `cutover_copy`
  copies its whole `[2026-07-17, repoint)` backlog on the next normal run, with the same per-seat
  verification and the same collapse-based idempotency. ADR-0020's machinery is not replaced; it is
  finally given the production row it was waiting for.

- **Interim becomes write-quiet by construction, not by assertion.** This is the load-bearing
  property. Every design that reached production for the stranded seats needed a guarantee that no
  further interim rows would arrive after the copy — because a copied row collapses that seat's
  watermark to the floor, and anything written afterwards falls outside every future window,
  permanently and silently. The repoint supplies that guarantee as a *fact about the topology*
  rather than a claim an operator types.

- **Write-quiet is measured on `meta.processed_batches.processed_at`, over a 24-hour window, with no
  override.** The sweep refuses unless `now() - MAX(processed_at) >= interval '24 hours'` on
  interim, printing the measured age either way.

  That column defaults to `now()` on the *server* (`db/schema.sql`) and is claimed by every batch
  that writes rows (`sink/src/cc_otel_sink/store.py`), so it is an exact "when did interim last gain
  rows" clock. It is deliberately **not** `MAX(ts)` / `MAX(event_time)`: those are client-side, so a
  laptop with a skewed clock or a long-buffered batch would land rows now carrying an old timestamp
  and an event-time guard would read "quiet" while interim was actively receiving. ADR-0020 records
  that `raw.*` carries no ingest timestamp — true of `raw.*`, and `meta.processed_batches` is where
  that clock actually lives.

  A fixed constant rather than a flag, and no `--force` twin: sweeping early is a decision about
  permanent data placement whose failure mode is silent, and a knob invites lowering it under time
  pressure, which is the one thing the guard exists to prevent.

- **What the repoint cannot reach gets one terminal sweep** (#409). A seat whose machine never emits
  again — long leave, departure, wiped laptop — still produces no production row and is still
  skipped. For those seats only, `tools.cutover_copy --sweep` copies `[2026-07-17, ∞)` instead of
  skipping.

  **The target is a seat absent from production's raw `watermarks()` output entirely** — not "absent
  above the floor". `cutover_copy` already drops seats whose watermark sits at or below the floor (a
  client clock skewed past two weeks). Such a seat's `MIN()` is that pre-floor row and never moves,
  so it could never self-exclude: it would re-qualify on every run and duplicate its rows into a
  table with no primary key (ADR-0017). Self-exclusion has to come from the seat's mere presence in
  production.

  **The mechanism is `timestamptz 'infinity'`**, seeded into the existing watermark scratch table for
  the target seats. It compares greater than every finite timestamp, so the census, the copy, the
  per-seat verification, the rollback-on-mismatch path and the dual-send probe are all correct
  unchanged — no second code path, and idempotency is the same collapse the normal path relies on:
  once swept, the seat has production rows, so it is no longer a target and its normal window is
  `[floor, floor)`.

- **The sweep runs on the 24-hour clock, weeks before decommission, not at #248's gate.** Its
  correctness depends only on interim being permanently write-quiet, not on the seat being
  permanently gone: a swept seat that later returns emits through interim's repointed front door
  straight into production, so nothing strands. Running early gets the missing window into the report
  sooner and — more importantly — lands the *retroactive* shift in production's historical
  aggregates while the production report is still being validated (#247), rather than a month after
  people start quoting its numbers.

- **#244's rollback dies at the repoint.** "Re-push the interim-built artifact" restores nothing once
  interim's sink writes to production. The repoint therefore lands **after #247** (report repoint) —
  before it, the published report still reads interim and the repoint would flatline it — and the
  early sweep commits to the repoint being permanent, which is the same commitment the dead rollback
  already forces.

## Considered options

- **`REVOKE INSERT ON raw.metrics, raw.events FROM cc_otel_ingest` on interim**, making it
  unwritable and verifiable in-band via `has_table_privilege`. Rejected. It buys write-quiet by
  *dropping* a live seat's rows: the sink's insert fails, the rows exist nowhere, and unlike the
  stranding it prevents they miss the archive too. The repoint achieves the same guarantee while
  keeping every row.

- **An operator assertion flag** (`--interim-is-quiet`). Rejected: a claim the tool cannot check,
  failing open, with an invisible failure — nobody notices until a seat's post-sweep rows never
  arrive, by which time interim is deleted.

- **A staleness heuristic on event time** ("no interim row for N days"). Rejected: four of the
  holders measured on 2026-08-03 were already 7–13 days quiet with their machines alive, and
  client-side timestamps cannot distinguish a quiet environment from a late flush.

- **Leave it archive-only, as ADR-0020 wrote it.** Rejected on the 51% figure. Losing the single
  largest contributor's entire pre-cutover window from the report, to avoid one Container App
  setting change, is not a trade worth making.

- **Sweep only at the decommission gate**, as #409 was originally filed. Rejected once the repoint
  removed the reason for it: the sweep only needed to be last when a swept seat could still write to
  interim afterwards.

## Consequences

- **ADR-0020's "seats that never flip keep their rows in interim" no longer holds**, and its
  consequence "the copy runs per seat as each seat flips" gains a terminal case. The population it
  described shrinks to seats that never emit again, and even those reach production via #409.

- **#409 and #248 are decoupled.** The sweep must precede `az group delete rg-cc-otel-interim`, but
  it no longer gates it and the two-week stability gate no longer gates the sweep.

- **Production has two writers.** Both sinks share production's `meta.processed_batches`, so
  batch-hash idempotency covers a double-send, and reservoir blob names carry a `uuid4()`
  (`sink/src/cc_otel_sink/blob.py`), so two writers into the same container and day cannot collide.
  The interim sink's managed identity needs `Storage Blob Data Contributor` on the **production**
  storage account; without it the payload is accepted and the blob is silently dropped, because the
  reservoir write is best-effort by design (ADR-0005) — the same silent-failure item #244's gate
  called out, now repeated for a second identity.

- **A post-repoint watermark drag is accepted, and it is not bounded by a flush interval.** Event
  time is client-side, so a batch buffered before the repoint and flushed after it lands in
  production carrying a pre-repoint timestamp, dragging that seat's watermark below some of its own
  interim rows.

  **Amended 2026-08-04 (#415).** This ADR first bounded the drag at "roughly one flush interval per
  seat". The collector's sending queue is file-backed and survives restarts, so the real bound is
  queue depth: `mohamed.atallah`'s collector replayed a batch stamped `2026-08-03 03:31:28.595Z`
  through the repointed sink at `20:23`, ~17 hours later. That instant is his earliest interim row
  to the microsecond, so his watermark collapsed onto his own interim floor and `[floor, watermark)`
  became **empty** — the copy moves 0 of his 175 rows.

  Copying nothing is nonetheless **correct** for him: the same replay carried the whole backlog into
  production, which holds 177 metrics / 353 events against interim's 175 / 341. The drag is
  therefore not a data-loss mechanism on its own; what it destroys is the *evidence*, because a
  fully collapsed window is indistinguishable in the census from a seat whose rows never arrived.
  That is what the last consequence answers.

- **Two residuals are named and closed, not tracked.**
  - **Rows with no `user_email` are never swept**, whatever the count. They cannot participate in the
    watermark collapse, so a second `--execute` would copy them again into a table with no primary
    key. Gating on production holding no such rows fails too — production holds its own. They stay in
    #248 Part B's archive.
  - **The post-watermark tail** — rows at or above an already-flipped seat's watermark, from
    sessions resumed across the endpoint switch — is unrecoverable. `watermarks()` reads `MIN()`
    over production, so the first copy replaced each boundary with the floor. Recovery would need
    durable per-seat state (which ADR-0020 refused, so re-runs need no memory) or a row-identity key
    (`raw.*` has none, ADR-0017). `cutover_copy` prints each seat's pre-copy watermark as **run
    evidence** so a run's output says which window it moved; that log line is explicitly not a
    cursor and no recovery path is built on it.

    **Figures amended 2026-08-04 (#415).** First recorded as 835 metrics / 365 events. Measured as
    a **cutover shortfall** instead — the count production demonstrably lacks, rather than the count
    held above a watermark — it is **1,524 metrics / 834 events** across three seats
    (`engy.salem` 759/0, `hadeel.sharaf` 654/799, `marwa.mehanna` 111/35). The original figure came
    from the bucket that cannot distinguish an already-copied row from a missing one, so it was
    never a measure of this residual. Still accepted and still not tracked: recovery would mean
    hand-bounding a per-seat copy into an unkeyed table, unverifiable afterwards, for ~2,400 rows.

- **Every run reports a cutover shortfall per seat, because the census buckets cannot** (added
  2026-08-04, #415). `cutover_copy` prints, per table, how many of interim's rows above the floor
  production demonstrably lacks: `sum(max(interim - production, 0))` grouped by `(user_email, UTC
  day)`, naming each seat and flagging the ones with no production row at all as sweep targets.

  It exists because `held_above` conflates three populations — already copied, replayed straight
  into production by a returning collector, and genuinely missing — and nothing distinguishes them:
  the copy never deletes from interim, and a copied row collapses that seat's watermark onto itself,
  so its rows re-report as held on every later run. Per-seat verification cannot cover the gap
  either; it compares `[floor, watermark)` on both sides, and a collapsed window makes that
  `0 == 0`, passing vacuously. Measured 2026-08-04, `held_above` read 303,283 metrics against an
  actual shortfall of 30,640.

  **The day grain is load-bearing.** A flat per-seat count is blind by the seat's own post-flip
  production volume — `ahmed.gharib` holds 14,141 *more* metrics rows in production than in interim,
  a surplus that would absorb any pre-flip rows the copy missed. Bucketing by UTC day confines the
  overlap to the single day a seat's flip falls on, which makes the figure a **lower bound** rather
  than a possibly-negative wash.

  Counts, not row identities: `raw.*` has no primary key (ADR-0017), so a shortfall says how many
  rows production lacks, never which. It is a detector and deliberately not a recovery cursor — no
  automated action is taken on it, and a non-zero shortfall does not fail a run, because the
  accepted residuals above are permanently non-zero.

- **Production's historical aggregates move when the sweep runs.** Every mart that reads `raw.*`
  does so through `LEFT JOIN`s only (`db/views/marts/dim_user.sql`, `fact_session.sql`) and the seat
  marts derive from the roster independently of telemetry (`dim_seat.sql`, `fact_seat_day.sql`), so
  swept rows surface with no roster membership needed — including for a departed seat, since roster
  drops are immutable dated snapshots (ADR-0009) that still cover the days they held the seat. The
  flip side is that figures quoted from production before the sweep will not match figures quoted
  after it.
