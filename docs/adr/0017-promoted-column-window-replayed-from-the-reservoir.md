# The promoted-column window is replayed from the reservoir

**Status:** accepted — **amends ADR-0002**, which rules out backfilling history into a fresh schema.

ADR-0002 rejects a one-time backfill of POC pilot data, and ADR-0006 carves interim out of that for
the mapped pilot history. This is a third act, and neither of the first two: no old-schema rows are
translated and no new rows are invented. Interim's **own** canonical redacted blobs (ADR-0005) are
re-driven through the **current** sink so the 29 promoted `(table, column)` pairs landed by #371 and
#370 carry values back across the recent window, instead of starting at the 2026-07-30 06:16Z image
rollout (#373). Same rows, same grain, same source bytes — only the column set widens.

Without it, every promotion decided in #357 / #358 / #359 would describe only post-rollout
behaviour, while each of those decisions was argued from measurements over the Jul 18–28 window. The
report would be unable to show the very things the curation effort promoted.

## Decisions

- **Interim only, event window 2026-07-17 → 2026-07-30.** Prod is out of scope for the whole
  curation map, replay included (#246 owns the prod reservoir).
- **The window starts Jul 17, not Jul 18.** The map's Notes excluded Jul 14–17 because metrics blobs
  do not reconcile with raw rows there. Re-measured against today's reservoir, that is one day too
  wide: Jul 17 reconciles **exactly** — 234 = 234 `raw.metrics` rows, 13,628 = 13,628 `raw.events`
  rows. Jul 16 stays out (3,228 blob rows vs 9,474 raw metrics; 14,404 vs 15,686 events), as do
  Jul 14–15. Rows before Jul 17 keep their promoted columns NULL permanently, including the 1.53M
  rows backfilled under ADR-0006, which have no blob to read at all.
- **Correctness rests on three measured invariants, not on the tool's docstring.** `tools.replay`
  deletes raw rows by **event time** and re-POSTs blobs by **ingest-date partition**, so the two
  addressings only agree if the data says they do. Before any mutation:
  - **Skew is zero at the window's outer edge, and non-zero at every day boundary inside it.** No
    record in any in-window partition carries an event time before Jul 17, so the first partition
    re-inserts nothing beside rows the delete never reached. Within the window it is the opposite:
    `dt=2026-07-24` holds 15,775 metrics records while event-day Jul 24 totals 15,747 — 28 records
    that ingested on Jul 24 carrying a Jul 23 event time, and a comparable straddle at every other
    midnight. **That is the measurement that forces a whole-window delete** (see below); an
    outer-edge zero says nothing about the interior.
  - **Reconciliation is exact.** Blob-derived rows equal raw rows on all 12 frozen days, both
    signals. The replay restores precisely what it deletes; no row in the window came from a batch
    with no blob.
  - **Batch hashes are stable.** For 84 sampled blobs, `sha256(gunzip(blob))` — the hash the tool
    clears — equals `sha256(canonical_bytes(redact(payload)))`, the hash the sink re-claims. Had the
    two diverged (a plausible outcome after #369 denied `tool_parameters`, changing what redaction
    strips), a re-POST would have hit a hash the delete never cleared and been a silent no-op.
- **One whole-window delete, then every blob — not a pass per day.** A pass for day D deletes
  event-day D but re-POSTs partition `dt=D`, whose straddle records carry event-day **D-1**. Those
  rows were never deleted, so the pass duplicates them; run the neighbouring day afterwards and it
  deletes them without restoring them, because they live in a partition it does not read. Per-day
  passes therefore compose **only** in strictly ascending order, where each day's delete precedes
  the next day's insert — and that serialises the slowest phase of the job. A single
  `[Jul 17, Jul 31)` delete followed by all 21,855 blobs has no boundary to get wrong at any order
  or concurrency.

  This was learned the expensive way: the first execution ran per-day passes across four parallel
  workers, on a zero-skew measurement that only covered the window's outer edge. It left ~150 rows
  of 565k duplicated or missing at day boundaries, and was corrected by the whole-window pass, after
  which all 13 frozen days matched their pre-replay counts exactly, both signals.
- **The whole-window delete is what races live ingest, and the live day absorbs it.** A batch landing
  between the pass's blob listing and its delete has its rows removed while its blob is not in the
  re-POST set — and its ledger hash survives, so a plain re-POST would be a no-op. Measured after
  the corrective pass: Jul 30 short by 275 metrics / 183 events, Jul 29 exact. Live-day passes repair
  it — safe here because `dt=2026-07-30` carries no Jul 29 straddle (event-day Jul 29 totals exactly
  the `dt=07-29` partition) — but they converge to a **floor, not to zero**: each pass restores its
  predecessor's losses and incurs its own race, so the residual settles at roughly one pass-duration
  of ingest. Measured across three further passes: 275/183, then 105/55, then **69 metrics / 39
  events** (0.5% / 0.35% of the live day). Reconciling the live day exactly means replaying it once
  it is frozen, not repeating passes while it is live.
- **The replay sink is the deployed image, run locally with the reservoir deliberately
  unconfigured.** `CC_OTEL_BLOB_*` unset makes `BlobReservoir.from_settings` return a
  `NullReservoir`. Left set, each of the ~18k re-POSTs would write a **new** blob under *today's*
  `dt=` — near-doubling the reservoir, and poisoning the compacted parquet (ADR-0015) that
  `tools.compact` derives from partition contents. This is the single most destructive way to get
  the replay wrong, and nothing in the tool prevents it.
- **The image, not the working tree.** `ghcr.io/gharib89/cc-otel-sink:5742436…` is the artifact ACA
  is running, so a replay through it cannot populate a column the live fleet does not. `main` at
  `5b414fb` was verified equivalent for this purpose — its `column_spec` resolves to exactly the
  interim schema (`raw.events` 73 columns, `raw.metrics` 32, no difference either way) and the parser
  is untouched since the deploy — but equivalence checked is not the same as the artifact itself.

## Considered options

- **Forward-only: no replay** — the option ADR-0002's letter implies. The promoted set would carry
  history nowhere, so the first month of every new column reads as an outage rather than as absence
  of history, and the marts' own trend visuals would start at the rollout.
- **`UPDATE raw.*` in place from the blobs, no delete** — attractive because it never removes a row,
  and unimplementable: `raw.*` has no primary key by design (idempotency lives in
  `meta.processed_batches`, not a row identity), so there is no key to match a blob record back to
  its row.
- **One whole-window `--execute`** — one command, one delete, and a re-POST phase long enough that
  live ingest lands inside it. Rejected above.
- **Extend the window to Jul 14** — loses data. Those partitions hold a fraction of the rows the
  delete would remove (3 metrics blobs against 7,617 rows on Jul 14), so the replay would destroy
  history rather than widen it.

## Consequences

- **The window is now replayable, and that cuts both ways.** Any future promotion can carry history
  the same way for as long as the blobs live; equally, this is a documented precedent for deleting
  live raw rows, so the three invariants above are the price of using it — not optional preamble.
- **`meta.processed_batches` is pg_cron-trimmed to 7 days**, so for the older half of the window the
  ledger clear was already a no-op. A replay far enough back never needs the ledger at all; one
  inside 7 days does, which is why the tool clears it rather than checking whether it must.
- **The marts refresh is hourly (pg_cron).** A refresh landing mid-replay reads a partially restored
  window and produces one short snapshot; the next refresh corrects it. The replay ends with an
  explicit `marts.refresh_all()` rather than waiting for the cron.
- **The live day carries an accepted 69-metrics / 39-events shortfall** until it is replayed frozen.
  Every frozen day in the window reconciles exactly (delta +0 against the pre-replay snapshot, both
  signals); only 2026-07-30 does not, and no per-day count anywhere in the window is *above* its
  pre-replay value, so nothing was duplicated.
- **`workflow_name` is emitted by the fleet, contrary to #373's premise.** 216 rows, one distinct
  value (`databricks-q-scoring`), one session, 2026-07-25 — an ITWorx developer's own GitHub Actions
  run, not this repo's CI. The replay is what made the column provable at all; `status_code` likewise
  resolved to 35 rows / 4 distinct.
- **ADR-0002 stands for production.** Nothing here backfills prod, and nothing here licenses
  translating old-schema history into a fresh schema — the two things ADR-0002 actually rejects.
