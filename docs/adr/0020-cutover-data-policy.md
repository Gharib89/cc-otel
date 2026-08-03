# The cutover data policy: production inherits interim's live telemetry from 2026-07-17

**Status:** accepted — **amends ADR-0002**, which starts production on an empty schema-v2. Records
the cutover data policy decided in #83; implemented by #245 (raw copy), #246 (reservoir copy) and
#248 Part B (interim decommission). **Amended by ADR-0021**, which repoints interim's sink at
production and sweeps the seats that never flip — so "seats that never flip keep their rows in
interim" below no longer holds.

ADR-0002 rejects translating POC pilot history into a fresh schema, and the cutover is not that.
Interim and production run the same schema-v2 behind the same sink image, so moving the recent
window is an **identity copy** of the same fleet's own telemetry — no mapping layer, no
old-schema/new-schema translation, and therefore none of the bug class ADR-0002 was written to
avoid. What that ADR actually rules out stays ruled out: ADR-0006's mapped pilot history remains in
interim and never reaches production.

ADR-0002 has been amended twice before, both times for interim: ADR-0006 carved interim out of it
for the mapped pilot history, and ADR-0017 replayed interim's own reservoir across this same window.
This is the first amendment that reaches production.

## Decisions

- **The boundary is `ts >= '2026-07-17 00:00:00+00'`, one edge with three independent reasons.**
  Interim's own live telemetry effectively begins there — the POC's last metric is
  `2026-07-16 23:27 UTC` (ADR-0016). ADR-0017's replay floor is the same date, because Jul 17 is the
  first day whose reservoir partition reconciles exactly with raw (234 = 234 metrics rows,
  13,628 = 13,628 events rows) while Jul 16 does not (3,228 blob vs 9,474 raw metrics; 14,404 vs
  15,686 events). And everything below it in interim `raw` is either ADR-0006's mapped pilot history
  — the thing ADR-0002 keeps out of production — or live rows whose promoted columns are permanently
  NULL. One date satisfies all three; no separate judgement call was needed.

- **Both stores move, on the same boundary.** Raw Postgres (#245 — `tools.cutover_copy`, a
  client-side `COPY` pipe over `raw.metrics` and `raw.events`) and the blob reservoir partitions (#246 — `azcopy`, same paths). Holding one window
  across both is what keeps replay and column curation (ADR-0017, #16) working from prod storage over
  the pre-cutover weeks; a Postgres-only copy would leave production with rows it could never
  re-derive.

- **No dedup, because the row sets are disjoint.** Each tracked machine's installer bakes exactly one
  collector endpoint, so a machine emits to interim or to production, never both, and the copy cannot
  produce a duplicate. The one precedent for the other outcome — ADR-0006's backfill "drops the
  cutover sessions that dual-sent" — came from replaying the POC's *own history* into interim, where
  a session already present live could arrive a second time from the dump. Nothing here replays
  history: the window opens where interim's live telemetry begins. Should the flip produce a
  dual-sent session anyway, nothing in this policy removes it — detecting one belongs to #245's
  verification step, and a plain interim-versus-production row-count match will not do it: production
  already holds its own #244 validation rows inside the same window. Re-runnability is a separate
  concern, settled by the flip watermark below.

- **The copy is bounded per seat by a flip watermark, so a re-run deletes nothing
  production-native.** Revised 2026-08-02 (#244 grilling); supersedes the
  **delete-window-then-copy** rule this ADR first recorded, which was destructive by construction.
  `raw.metrics` and `raw.events` carry an event time (`ts` and `event_time` respectively) and
  identity columns and nothing else — no
  ingest timestamp, no batch linkage — and `meta.processed_batches` is `(batch_hash, processed_at)`
  with no row linkage, so **nothing in production distinguishes a copied row from a
  production-native one**. A global `ts >= '2026-07-17'` delete therefore removes production's own
  post-flip telemetry and cannot restore it, because those rows are in production only. `raw.*` has
  no primary key by design — idempotency lives in `meta.processed_batches` (ADR-0017) — so
  `ON CONFLICT` was never available either.

  The bound that works is derived from production itself. A seat's **flip watermark** is
  `MIN(<event time>)` over that seat's production rows — the moment its machine started emitting to
  production — computed per table, since the two tables name that column differently. The copy moves
  interim rows below the seat's watermark and **deletes nothing at all**. Amended 2026-08-03 (#245):
  this bullet first said the copy "bounds its delete identically", which is an unconditional no-op —
  by the definition of `MIN`, no production row sits below that seat's own minimum — so the
  implementation carries no delete step. Re-runnability comes from the watermark instead: a copied
  row *becomes* production's new minimum for that seat, collapsing the next run's window to
  `[floor, floor)`, so duplicates are unreachable with no delete needed to prevent them.
  That matters because **the flip is staggered, not atomic**: IS pushes on a
  90-minute cadence and a powered-off or off-VPN machine flips whenever it next ticks, so
  stragglers are the expected case and the copy has to be re-runnable rather than one-shot.

  **The watermark is per seat, not per machine, because no machine identifier exists.**
  `process_owner`, `terminal_type`, `service_name` and `os_type` are the closest columns and none
  identifies a device, so a seat running two machines that flip at different times would strand the
  later machine's interim rows between the two flip moments. Measured 2026-08-02: interim
  `raw.metrics` carries **17 distinct `user_email` over the trailing 7 days**, one machine each, so
  seat and machine coincide and the limit is not live. That same 17 is the denominator for #244's
  gate — every seat must have appeared in production before the copy is complete — and it replaces
  watching interim for silence, which cannot distinguish a finished flip from a fleet that is merely
  powered off.

- **Sessions straddling the boundary lose their pre-midnight rows, accepted.** A session live at
  `2026-07-16 23:59` keeps only its post-boundary rows in production; the rest stays queryable in
  interim until decommission, and in the archive dump after that. The affected population is
  deliberately left unquantified, because nothing measured can quantify it: Jul 16 holds 9,474 raw
  metrics and 15,686 raw events (ADR-0017), and those are ADR-0006 pilot rows and interim-live rows
  mixed with no discriminator — the same reason Jul 16 sits outside ADR-0017's replay window.
  Whatever the count, the effect is bounded to one midnight and reaches no mart aggregate except a
  session-grain duration, which reads short for the sessions concerned.

- **Sessions straddling the fleet flip merge in the marts on `session_id`.** A different boundary
  with a different mechanism: at the flip (#244) a machine's rows land partly in interim and partly
  in production, and the copy brings the interim half over. `session_id` is a degenerate dimension on
  every fact row (#9), so the marts re-assemble the session with no special handling.

- **The interim decommission is gated and archive-first.** Two weeks of stable production
  post-cutover — daily report refresh green, freshness tile healthy, no new production `dq_finding` —
  then a human go/no-go with Ahmed, never automatic (#248 Part B). Before
  `az group delete rg-cc-otel-interim`, a full `pg_dump -Fc` of interim `cc_otel` lands in the
  production storage account's `archive` container — a **sibling container, never a prefix inside
  `raw`**, because a dump is unredacted while every reservoir blob is redacted at the sink (ADR-0005)
  and `tools.scrub` treats `raw` as its scrubbable surface (ADR-0016) — and is **verified by row
  count against the live server**, exactly as Part A did for the POC.

- **The POC half of that policy is already spent.** ADR-0016 pulled it forward for Azure consumption
  cost: the POC `otel` dump was taken, verified and uploaded — 103,095,676 bytes,
  `sha256 fe40f81e…ec02c971`, covering 2026-05-21 → 2026-07-16 — before `rg-cc-otel-poc` was deleted
  on 2026-07-28 (#248 Part A). This ADR therefore requires the interim dump only.

## Considered options

- **Start production truly empty, ADR-0002 to the letter.** Rejected. The fleet has been emitting
  since Jul 17 and the adoption story *is* that history; every trend crossing the flip would restart
  at zero. The reason ADR-0002 gave for refusing a backfill — translation bugs — does not apply to an
  identity copy, so the cost of holding the line is real and the risk it buys is not.

- **Copy everything interim holds, pilot history included.** Rejected. It re-imports the lossy
  schema-v1→v2 mapping (ADR-0006) into the one environment ADR-0002 keeps clean, for 2–6 developers
  of history that the 150–200-developer rollout makes statistically irrelevant. The schema-v1 archive
  dump is the answer if anyone ever needs it.

- **Extend the boundary back to Jul 16 to save the straddling sessions.** Rejected. Jul 16's
  reservoir does not reconcile with raw (ADR-0017), so the reservoir half of the copy would be
  knowingly incomplete on exactly that day, and the raw half would drag ADR-0006 rows in alongside
  live ones on the same date with no clean discriminator short of re-deriving from the reservoir that
  does not reconcile there.

- **Dual-write during the parallel run** — the classic zero-loss cutover. Rejected: it needs a
  fleet-side change (a second exporter endpoint) pushed by IS on a 90-minute cadence and then unwound
  again, to avoid a one-shot `\copy`.

## Consequences

- **ADR-0002's "production starts fresh" now means "no old-schema history in production", not "no
  history".** The prohibition it carries is on translation, and that is intact — nothing in this ADR
  maps a schema-v1 row into schema-v2.

- **Production inherits the replay's shape, warts included.** The rows copied are interim's
  *post-replay* rows, so production gets the 29 promoted columns' history back to Jul 17 for free —
  and equally inherits whatever residual that replay left on its live day, `2026-07-30` (69 metrics /
  39 events short at last measurement), unless that day is replayed frozen in interim before the copy
  runs.

- **The copy runs per seat as each seat flips, not once after the fleet is quiet.** Amended
  2026-08-03 (#245): this consequence originally required fleet quiet, because a moving right edge
  would leave no verification able to settle. The per-seat watermark *is* a fixed right edge — a
  flipped seat writes no further interim rows, so its window closes the moment it flips and
  verifies independently of every other seat. #244 duly closed at 4 of 18 seats, with the rest
  gated on developer process restarts, and #245 re-runs until interim holds no rows above any
  seat's watermark.

- **Production's reservoir becomes replay-capable back to Jul 17** once #246 lands, so a future
  column promotion can carry history in production the same way ADR-0017 did in interim.

- **Interim stays the fallback until Part B's gate opens** (ADR-0016, CONTEXT.md *parallel cutover*).
  Until then two environments hold the same window, which is the point.
