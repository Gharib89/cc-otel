# Production inherits interim's live telemetry from 2026-07-17; nothing older crosses

**Status:** accepted — **amends ADR-0002**, which starts production on an empty schema-v2. Records
the cutover data policy decided in #83; implemented by #245 (raw copy), #246 (reservoir copy) and
#248 Part B (interim decommission).

ADR-0002 rejects translating POC pilot history into a fresh schema, and the cutover is not that.
Interim and production run the same schema-v2 behind the same sink image, so moving the recent
window is an **identity copy** of the same fleet's own telemetry — no mapping layer, no
old-schema/new-schema translation, and therefore none of the bug class ADR-0002 was written to
avoid. What that ADR actually rules out stays ruled out: ADR-0006's mapped pilot history remains in
interim and never reaches production.

This is the third act on ADR-0002 in sequence — ADR-0006 carved interim out of it, ADR-0017 replayed
interim's own reservoir across the same window, and this one carries that window forward to prod.

## Decisions

- **The boundary is `ts >= '2026-07-17 00:00:00+00'`, one edge with three independent reasons.**
  Interim's own live telemetry effectively begins there — the POC's last metric is
  `2026-07-16 23:27 UTC` (ADR-0016). ADR-0017's replay floor is the same date, because Jul 17 is the
  first day whose reservoir partition reconciles exactly with raw (234 = 234 metrics rows,
  13,628 = 13,628 events rows) while Jul 16 does not (3,228 blob vs 9,474 raw metrics; 14,404 vs
  15,686 events). And everything below it in interim `raw` is either ADR-0006's mapped pilot history
  — the thing ADR-0002 keeps out of production — or live rows whose promoted columns are permanently
  NULL. One date satisfies all three; no separate judgement call was needed.

- **Both stores move, on the same boundary.** Raw Postgres (#245 — `\copy` of `raw.metrics` and
  `raw.events`) and the blob reservoir partitions (#246 — `azcopy`, same paths). Holding one window
  across both is what keeps replay and column curation (ADR-0017, #16) working from prod storage over
  the pre-cutover weeks; a Postgres-only copy would leave production with rows it could never
  re-derive.

- **No dedup, because the row sets are disjoint.** Each tracked machine's installer bakes exactly one
  collector endpoint, so a machine emits to interim or to production, never both, and the copy cannot
  produce a duplicate. Re-runnability is a separate concern and is **delete-window-then-copy**, not
  `ON CONFLICT`: `raw.*` has no primary key by design — idempotency lives in `meta.processed_batches`
  (ADR-0017) — so there is no conflict target to name.

- **Sessions straddling the boundary lose their pre-midnight rows, accepted.** A session live at
  `2026-07-16 23:59` keeps only its post-boundary rows in production. The volume left behind is the
  Jul 16 live remainder ADR-0017 measured — 3,228 metrics and 14,404 events — against a
  fleet-lifetime production dataset, and it stays queryable in interim until decommission and in the
  archive dump after that. Truncation is invisible in every mart aggregate except a session-grain
  duration, which reads short for those few sessions.

- **Sessions straddling the fleet flip merge in the marts on `session_id`.** A different boundary
  with a different mechanism: at the flip (#244) a machine's rows land partly in interim and partly
  in production, and the copy brings the interim half over. `session_id` is a degenerate dimension on
  every fact row (#9), so the marts re-assemble the session with no special handling.

- **The interim decommission is gated and archive-first.** Two weeks of stable production
  post-cutover — daily report refresh green, freshness tile healthy, no new production `dq_finding` —
  then a human go/no-go with Ahmed, never automatic (#248 Part B). Before
  `az group delete rg-cc-otel-interim`, a full `pg_dump -Fc` of interim `cc_otel` lands in the
  production storage account's `archive` container and is **verified by row count against the live
  server**, exactly as Part A did for the POC.

- **The POC half of that policy is already spent.** ADR-0016 pulled it forward for Azure consumption
  cost: the POC `otel` dump was taken, verified and uploaded on 2026-07-28 (103,095,676 bytes,
  `sha256 fe40f81e…ec02c971`, covering 2026-05-21 → 2026-07-16) before `rg-cc-otel-poc` was deleted.
  This ADR therefore requires the interim dump only.

- **`archive` is a sibling container, never a prefix inside `raw`.** A dump is unredacted — raw
  `user_email`, every promoted column — whereas every blob in the raw reservoir is redacted at the
  sink (ADR-0005) and `tools.scrub` treats that container as its scrubbable surface. A prefix would
  make both claims false (ADR-0016).

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
  and equally inherits whatever residual ADR-0017's replay left on its live day (69 metrics /
  39 events short at last measurement) unless that day is replayed frozen in interim before the copy
  runs.

- **The copy runs after the fleet is quiet on interim** (#245 gated on #244), or the window has a
  moving right edge and the spot-check that compares interim-vs-production row counts can never
  match.

- **Production's reservoir becomes replay-capable back to Jul 17** once #246 lands, so a future
  column promotion can carry history in production the same way ADR-0017 did in interim.

- **Interim stays the fallback until Part B's gate opens** (ADR-0016, CONTEXT.md *parallel cutover*).
  Until then two environments hold the same window, which is the point.
