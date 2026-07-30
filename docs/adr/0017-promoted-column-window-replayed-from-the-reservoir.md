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
  - **Skew is zero.** Across every `dt` partition in the window, **0** records carry an event time
    before the window start. Records inside a partition whose event time predates the deleted range
    would be re-inserted *beside* rows that were never deleted — the duplication mode this rules out.
  - **Reconciliation is exact.** Blob-derived rows equal raw rows on all 12 frozen days, both
    signals. The replay restores precisely what it deletes; no row in the window came from a batch
    with no blob.
  - **Batch hashes are stable.** For 84 sampled blobs, `sha256(gunzip(blob))` — the hash the tool
    clears — equals `sha256(canonical_bytes(redact(payload)))`, the hash the sink re-claims. Had the
    two diverged (a plausible outcome after #369 denied `tool_parameters`, changing what redaction
    strips), a re-POST would have hit a hash the delete never cleared and been a silent no-op.
- **Day-by-day passes, not one whole-window invocation.** One `--since D --until D --execute` per
  day. A single whole-range pass deletes everything up front and then re-POSTs for the length of the
  window; any batch ingested inside that gap has its rows deleted and never restored. Per-day passes
  bound the exposure to one partition, and a **frozen** partition (`dt` < today) can never gain
  another blob, so for those days the exposure is nil rather than merely small. Only the live day
  races ingest: it runs last and repeats until its blob-derived and raw counts agree.
- **Days run in parallel, licensed by the zero-skew measurement.** With no cross-partition skew,
  day passes share no rows and their order carries no meaning; four concurrent workers cut the
  wall-clock roughly fourfold. Had skew been non-zero, the passes would have had to run ascending so
  each day restored what the previous deleted.
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
- **ADR-0002 stands for production.** Nothing here backfills prod, and nothing here licenses
  translating old-schema history into a fresh schema — the two things ADR-0002 actually rejects.
