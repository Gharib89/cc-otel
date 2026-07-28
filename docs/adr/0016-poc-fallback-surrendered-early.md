# The POC fallback is surrendered early, for cost

**Status:** accepted — **amends ADR-0004**, which promised the POC env stays live as fallback
until the adoption report refreshes green off production.

The POC stopped being a fallback long before it stopped billing. It stopped receiving telemetry
when the fleet moved to interim — `metrics` and `events` end at `2026-07-16 23:27 UTC`, and the
last write of any kind is a span at `2026-07-18 03:04 UTC` — so its `Standard_B2s` / 32 GB
Postgres, its ACA environment and its Log Analytics workspace ran for ten days with no writer and
no reader. Meanwhile the thing that promise insured against is a *prod* cutover that has not
begun: the semantic model still reads `ccotel-pg-interim`. And interim runs the same stack **plus**
the mapped pilot history (ADR-0006), so interim — not the POC — is what a bad prod cutover falls
back to. Paying for a rehearsal environment nobody can fall back to is the whole cost of keeping
the ADR-0004 wording intact, so we archive the POC database and delete `rg-cc-otel-poc` ahead of
the parallel-cutover gate.

## Decisions

- **Archive first, verified against the live server, then delete.** A `pg_dump -Fc` of the POC
  `otel` database (schema-v1 original) is taken and proven *before* the RG delete, not after:
  103,095,676 bytes, `sha256 fe40f81e…ec02c971`, covering `2026-05-21` → `2026-07-16`. The proof is
  a row count per base table matched against the live server — `metrics` 1,688,773, `events`
  236,189, `spans` 666,634, `ingest_errors` 0, `schema_migrations` 9. Those are all five base
  tables; the other 55 public relations are plain VIEWs whose definitions travel in the dump (231
  TOC entries) and carry no data by design.
- **Verification by full decompression + counts, not a restore into a container.** Docker was down
  when the dump was taken, so every data block was read by decompressing the archive end to end
  instead of restoring it. Same proof of a readable archive, no daemon; the restore recipe travels
  in the archive manifest for whoever needs the data later.
- **The archive lives in its own `archive` container, not under a prefix inside `raw`.** A dump is
  unredacted — raw `user_email`, `organization_id`, session ids, every promoted column — whereas
  every blob in the raw reservoir is redacted at the sink (ADR-0005) and `tools.scrub` treats that
  container as its scrubbable surface. An `archive/` prefix inside `raw` would have made both
  claims false. Same storage account, so it inherits one credential and one RBAC surface, exactly
  as ADR-0015 reasoned for `compacted`.
- **Declared in Bicep like every other container** (`iac/modules/storage.bicep`), even though the
  container was created out-of-band to unblock the upload. Infra comes from `iac/`, and no workflow
  deploys it — the next operator-run `bootstrap/bootstrap.ps1 -Environment prod -Step deploy` is
  therefore a no-op rather than a container that exists only in someone's shell history.
- **Writing the blob needs a data-plane grant, and `Owner` is not one.** The prod storage account
  sets `allowSharedKeyAccess=false`, so blob writes authenticate as an Entra identity; RG **Owner**
  created the container but cannot write into it. The operator grants themselves
  `Storage Blob Data Contributor` on the account — the same prerequisite `.env.prod` already
  documents for `tools.sweep` / `scrub` / `replay`, never applied to prod until now.
- **The POC's dev `cc_otel` database is dumped but not archived.** 7.7 MB holding only this repo's
  migrations over an empty schema, reproducible via `scripts/dev-migrate.sh`. Keeping it would
  imply it carries something the repo doesn't.
- **`.env` `DATABASE_URL` repoints to the interim _read-only_ login**, `cc_otel_read_user`, not
  the admin. This is the value silently inherited by `dbmate` / `spec_sync --check` /
  `roster_load`, so after the delete it must name a live database — and the least dangerous live
  one. It covers `raw.metrics`, `raw.events`, `meta.*` and all of `marts`; staging views and writes
  take the explicit `.env.interim` admin URL.
- **This surrenders the POC only.** Interim decommission keeps its gate — two weeks of stable prod
  post-cutover, human go/no-go (#248 Part B). Nothing here is precedent for deleting the
  environment that currently *is* the fallback.

## Considered options

- **Keep the POC live to the letter of ADR-0004** — the option this ADR rejects. It buys a fallback
  for a cutover that has not started, from an environment that has neither the current fleet's
  telemetry nor the mapped pilot history, at ~ten days of B2s + ACA + Log Analytics already spent.
- **Stop the Postgres server instead of deleting the RG** — Azure auto-restarts a stopped Flexible
  Server after 7 days, and storage, the ACA environment and Log Analytics keep billing regardless.
  A stop is a reminder to come back, not a decision.
- **Keep the dump only on the operator's laptop** — one copy, one disk, no checksum anybody else
  can verify. The archive container costs cents for ~98 MB.
- **Backfill the unpromoted schema-v1 keys into interim before deleting** — the honest way to make
  the interim copy lossless, and out of scope: it re-opens ADR-0006's mapping and there is no
  demand case for the `attrs` / `resource` JSONB today. The dump is the answer if one appears.

## Consequences

- **The schema-v1 original survives only as this dump.** The interim copy of the same pilot history
  is lossy by design (promoted columns only, no `attrs` / `resource` JSONB — ADR-0006). Anything
  needing the unpromoted keys or the v1 shape restores the archive.
- **The ambient `DATABASE_URL` flips from harmless to dangerous.** It used to name a decommissioned
  server, so a `dbmate` / `spec_sync --check` / `roster_load` invocation that silently inherited it
  did nothing; it now names the **live** interim database. The existing guards are what stand
  between the two — `scripts/ship/local-gate.sh` unsets it, the `--check` gates want
  `env -u DATABASE_URL`, and `roster_load` prints its resolved target host before reading the file.
  Every guard rationale that read "would otherwise write into a decommissioned database" is now
  the opposite warning.
- **Gate G5 is fleet cutover + *interim* decommission** (`bootstrap/README.md`). The POC half of
  that gate is spent.
- **ADR-0004's parallel-cutover consequence no longer holds as written**, and CONTEXT.md's
  *parallel cutover* entry now describes interim as the fallback. ADR-0002 and ADR-0006 are
  untouched: production still starts fresh, and interim still carries mapped pilot history.
- Prod is unaffected. The prod reservoir azcopy (#246) and the interim decommission (#248 Part B)
  are unchanged.
