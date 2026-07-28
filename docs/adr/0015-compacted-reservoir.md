# A compacted reservoir: one parquet per (signal, day), in its own container

**Status:** accepted

Reading the reservoir costs ~22–31 s per full-day partition, and #352 measured *why*: the driver
is **file count, not bytes**. One partition (`signal=logs dt=2026-07-26`, 860 blobs, 2.83 MB
gzipped) took 21.8 s over `azure://` and still **9.6 s read from local copies with zero network** —
~11 ms of per-file overhead on both sides of the wire. 50 MB spread over 19,980 files therefore
costs orders of magnitude more than the same 50 MB in 30 files. A faster network is not the fix;
fewer files is.

So we add a second container holding one parquet per `(signal, day)` — a single `json VARCHAR`
column carrying the OTLP payload text — and teach the analysis read path to prefer it. Measured:
fetch 10–15 s → 0.6–1.6 s per partition, and the Jul 14 → 28 window from ~6–11 min to ~3.5 min.

## Decisions

- **Derived, additive, rebuildable — never the replay source.** `raw` stays the source of truth
  (ADR-0005). `tools.replay` re-POSTs the original blobs and `tools.scrub` rewrites them; neither
  ever addresses the compacted container. A compacted partition is a read cache: deleting the
  whole container costs ~21 s per partition to rebuild, ~12 min for the window.
- **Layout `signal=<metrics|logs>/dt=<YYYY-MM-DD>/part-0.parquet`** — the raw Hive prefix with a
  fixed leaf, so a compacted address differs from a raw one only in the file name, globs stay
  symmetric, and the OTLP-route-vs-registry-signal mapping keeps living in `partition_prefix`.
- **A separate container, not a prefix inside `raw`.** `tools/_window.globs` anchors at `signal=`,
  so a `compacted/` prefix inside `raw` would sit one glob-widening away from being swept,
  scrubbed, or replayed. A separate container makes "strictly additive" structural rather than a
  naming convention. Same storage account: one credential, one RBAC surface, one firewall config,
  and `configure_duckdb`'s account-scoped Azure secret already reaches it.
- **Named `compacted`, not `curated`.** "Curation" is already the column-classification flow
  (`CurationReservoir`, `docs/agents/column-curation.md`); `curated` would read as "the classified
  thing", which this is not.
- **Payload text, not a typed schema.** #352's open sub-question — does OTLP flatten to a stable
  parquet schema? — answers *no, and it need not*. One VARCHAR column is stable by construction,
  so `json.loads`, `fill_counts`, `attr_value_samples` and `Profile` are all untouched.
- **Never compact today's partition.** `blob.py` names each blob from ingest wall-clock UTC, so a
  blob always lands in *today's* `dt=` and nothing arrives late into a past partition. Every
  `dt < today` is frozen at UTC midnight; today's is still growing, and a file built for it goes
  stale within the hour. The read path falls back to `raw` for it.
- **On demand, no schedule.** Because past partitions are immutable, compaction is a
  once-per-partition-ever job: there is no drift to correct, only a backlog to catch up. The
  default target is every frozen partition with no counterpart, so one command catches up whatever
  is missing no matter when it last ran. Cost is ~42 s per day of backlog; the only consumer is
  local on-demand EDA (the Power BI refresh reads the Postgres marts and never touches the
  reservoir), and no compute could run it today anyway — `pg_cron` cannot reach blobs, there is no
  ACA job, and a GitHub Actions cron would need reservoir credentials in CI plus an egress path.
- **Declared in Bicep, never created by the tool** (`iac/modules/storage.bicep`) — infra comes from
  `iac/`. Needs a manual `workflow_dispatch` deploy per environment before the tool can write.
- **No lifecycle policy**, matching raw's keep-forever posture (#15) but for the opposite reason:
  raw is keep-forever because it is the source of truth, `compacted` because it is ~2 MB/day and
  cheap to rebuild. Nobody should read its retention as evidence that it is irreplaceable.
- **The sink never writes `compacted`; compaction runs under the operator identity** (`az login`,
  Storage Blob Data Contributor). Note what this is *not*: the Container App identity's
  `Storage Blob Data Contributor` assignment is scoped to the whole storage account
  (`iac/main.bicep`), so the sink identity retains the *permission* to write the new container —
  it simply never addresses it (`Settings.blob_container` is the only container the sink builds a
  client for). That is the accepted cost of the "one credential, one RBAC surface" decision
  above; tightening it to a per-container assignment is a separate change, not a guarantee this
  ADR makes.
- **Unset means today's behaviour exactly.** `CC_OTEL_BLOB_COMPACTED_CONTAINER` unset ⇒
  `read_payloads` reads raw as before, so a machine that has never compacted anything still runs
  the notebooks.

## Considered options

- **Record-grain (long-format) parquet** — measured ~1–2 s per partition on #352, faster still.
  Rejected: as prototyped it drops metric values and timestamps, and completing it means a second
  parse of OTLP into a store `raw.*` already covers at record grain, with a schema to keep in sync
  with the sink's parser. Not built without a demand case.
- **Typed-wide parquet over nested OTLP** — the option to not build; both viable layouts avoid it.
- **A second storage account** — isolates nothing that needs isolating and doubles the bootstrap.
- **Scheduled compaction** — no waiting consumer and no compute that can reach blobs today.
  Revisit when a second consumer reads wide on a fixed cadence, or catch-up grows past a couple of
  minutes; it would then attach to an ACA job beside the sink, not to CI.
- **Extending `tools.sweep` to read compacted too** — the one other legitimate candidate, and a
  separate decision. Only `read_payloads` gains the preference here.

## Consequences

- **`tools.scrub` staleness-invalidates a compacted partition.** Scrub rewrites raw blobs in place
  after a new `denied` classification; the compacted copy of that window still carries the denied
  key, so a deny is not complete until the window is re-compacted. `tools.compact --rebuild`
  (bounded by `--since`/`--until`) is that step, and it is now part of the deny flow in
  `docs/agents/column-curation.md` §6.
- The residual read cost is python compute in the notebooks, which only bites on a full-window
  re-cut — the case the frozen `docs/research/` cuts already serve.
- Prod is out of scope here; the prod reservoir azcopy is #246.
