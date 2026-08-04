# Claude Code Telemetry (cc-otel)

Captures Claude Code developer-usage telemetry from ITWorx developer machines into Postgres for a daily-refresh Power BI adoption report. One context: ingest → store → report.

## Language

### Signals

**Official telemetry**:
Metrics and events (logs) emitted natively by Claude Code's built-in OTel exporter (including the enhanced-telemetry beta). Covers tokens, LOC, commits, PRs, active time, model, effort, skills, MCPs, subagents, hooks, plugins. Traces are disabled in production (killed for volume; agent hierarchy forfeited — ADR-0001).
_Avoid_: native telemetry, CC OTel

**Wrapper telemetry**:
Gauges emitted by the statusline wrapper — only what official telemetry cannot provide: rate-limit utilization and reset countdown per window, labelled `user.email`, `session.id`, `window`. See ADR-0003.
_Avoid_: statusline metrics

**Rate-limit window**:
An Anthropic subscription quota period — `5h` or `7d` (plus model-scoped variants like `7d_sonnet`). Utilization is the Anthropic-computed used-percentage (0–100).
_Avoid_: quota, budget

**Pace**:
Utilization divided by elapsed fraction of the window — >1 means on track to exhaust the window before it resets. Basis of `projected_eow_pct`.

### Pipeline

**Wrapper**:
`cc-otel-wrapper.mjs` — sits in front of the user's real statusline command, forwards the statusline JSON unchanged, and pushes wrapper telemetry as a side effect.
_Avoid_: statusline script

**Collector**:
The OpenTelemetry Collector container — the only authenticated ingest boundary (bearer token); converts OTLP/protobuf → OTLP/JSON for the sink.

**Sink**:
Our FastAPI service that parses OTLP/JSON and writes rows to Postgres. Trusts the collector; never exposed externally.

**Adoption report**:
The slim daily-refresh Power BI report (successor to the POC report). Focus: productivity + adoption (tokens out, LOC, commits, PRs, active time, sessions, limits, model/effort mix, top skills/MCPs/subagents). Includes `cost_usd` as **API-equivalent value consumed** — not marginal spend, since subscription seats are flat per-seat (ADR-0007, decision #158).
_Avoid_: dashboard v2, current report

**Non-empty session**:
A session with at least one `prompt_id` — a human-initiated prompt turn, carried on `api_request` and related events. Sessions without one (statusline-only launches, `/resume` browsing) are empty and excluded from session counts and duration averages. (Counted as `COUNT(DISTINCT prompt_id)`, not the `user_prompt` event, which older Claude Code builds rarely emitted.)
_Avoid_: active session (that means something else — see `active_session_count`)

**Session duration**:
Wall clock: `last_seen_at − started_at` of a non-empty session. Distinct from **active time**, which is `active_time.total` (excludes idle) and feeds "avg active time per day".

### Data model

**Mart**:
A materialized view in the `marts` schema — the conformed star schema (dimensions, facts, bridges) the adoption report reads. Refreshed hourly by `pg_cron` inside Postgres via `marts.refresh_all()` before the Power BI refresh, each cycle logged to `mart_refresh_log`. Raw tables are archive + drill source.
_Avoid_: aggregate table, summary view

**DQ finding**:
A data-quality condition `marts.refresh_all()` detects and records — a session logged under two addresses, an emitter with no seat, a promoted cost diverging from its counter. A finding is the *condition*; the row is a **detection** of it. `marts.dq_finding` is an append-only log, so every still-true condition is re-detected on every hourly cycle and its row count is cycles × conditions, never a count of findings (ADR-0019). Consumers read `marts.dq_finding_current` — the current cycle, keyed on `MAX(detected_at)`, which is exact because a cycle is one transaction, and carrying each finding's `first_detected_at` (all-time) alongside `standing_since` (the start of its unbroken run of cycles). What a finding is *about* is its **subject**, recorded at insert at the grain the detector groups by — an email, a session-day, or the `'(dataset)'` sentinel — because `details` is a payload, not a key. Whether it drains is its **kind**: a **defect** is a condition someone can act on until it reaches zero, a **gauge** is permanently true by design (a recorded exclusion, an observation, a measured share). Four of the twelve detector types are gauges, so only a defects-only count can reach zero — which is what the `DQ Findings` card counts (#396). The log itself is provenance, kept the full retention window and never trimmed.
_Avoid_: data quality issue, DQ error, DQ alert, finding row, counting a gauge as a defect

**Raw reservoir**:
An Azure Blob Storage container (`raw`) holding the **redacted-raw** OTLP payloads — the full body with only secret-bearing fields stripped (`full_command`, `bash_command`, `file_path`, `error`), everything else kept verbatim. Purpose: keep Postgres lean while preserving raw for **drift** discovery and future-parser replay. Not the source of truth (the report reads Postgres marts); queried ad-hoc with DuckDB. See ADR-0005.
_Avoid_: raw dump, blob backup

**Compacted reservoir**:
A second Azure Blob container (`compacted`) holding one parquet per `(signal, day)` — a single `json VARCHAR` column carrying the same payload text as the **Raw reservoir** blobs, at the same Hive path with a `part-0.parquet` leaf. **Derived, additive and rebuildable**: it exists only because reservoir read cost is driven by file count (~11 ms per file), so a partition's ~860 blobs collapse to one. Written on demand by `tools.compact`, preferred by the analysis read path, never seen by `tools.scrub` / `tools.replay` — the **Raw reservoir** stays the replay source. See ADR-0015.
_Avoid_: curated reservoir (curation is the column-classification flow), parquet cache, blob archive

**Blob backend**:
`cc_otel_sink/blob_backend.py` — maps `Settings` to authenticated **Raw reservoir** container access (and, via `CurationReservoir.from_settings`' container override, the **Compacted reservoir**), and holds the one copy of the auth-precedence rule (connection string wins, else account URL + managed identity, else none). Both the sink (`BlobReservoir`) and the curation tools (`CurationReservoir`, `configure_duckdb`) build their clients through it; the `None` case is each caller's own policy.
_Avoid_: blob config, storage adapter

**Column spec**:
`cc_otel_sink/column_spec.py` — the authoritative machine-readable attr-to-column-to-status catalogue. The parser maps, store column tuples, and redaction denylist derive from it at import; `meta.column_registry` is its deployed projection. `tools.spec_sync` proves the two converge.
_Avoid_: attr map, column table

**Column registry**:
`meta.column_registry` — the deployed projection of the **Column spec** in Postgres: every promoted column and known `attrs` key with type, description, what it's useful for, status, and — for a `kept` key — its **kept basis**. Source of truth for the generated data dictionary, the sweep's live-drift check, and the basis-drift check.

**Drift**:
An `attrs`/`resource` key observed in the raw reservoir but absent from the column registry — the signal that Anthropic added new telemetry. Surfaced on demand by prepared DuckDB queries (`tools/`) over the reservoir; analysis is manual. Postgres cannot detect it — schema-v2 drops the JSONB there. Concerns *unclassified* keys only; a classified key whose evidence has gone stale is **basis drift**.
_Avoid_: basis drift (a distinct term, below)

**Kept basis**:
The reason an attribute key is classified `kept` rather than promoted or denied, drawn from a closed set: **`nature`** (identity or unbounded cardinality — what the key *is*), **`constant`** (one value across the observed window), **`collinear`** (functionally determined by a named partner key on the same record), **`thin`** (reaching too few seats to argue a value case), **`redundant`** (the information is already carried elsewhere in the schema, possibly at another grain). Only `nature` is unfalsifiable by construction; the rest are claims about observed data that a fleet change can invalidate, and `constant` / `collinear` / `thin` have machine predicates that re-derive them. `redundant` is a cross-grain claim no single record answers, so it carries its argument in the registry row's `notes` and is re-checked by hand. Every `kept` key carries exactly one.
_Avoid_: kept reason, keep rationale, classification evidence

**Basis drift**:
Live reservoir data contradicting a key's **kept basis** — a second value under `constant`, a broken dependency under `collinear`, seat spread under `thin`. Unlike **drift** it concerns keys already classified, so no new key appears; the classification is simply no longer true. Detected on demand against a recent window by `tools.basis_drift`; `nature` and `redundant` keys are exempt (the first cannot drift, the second has no single-record predicate).
_Avoid_: stale classification, kept-key drift, evidence rot

### Presentation

**KPI band**:
The horizontal stack of paired cards across the top of an **adoption report** page — a label row, a value row, and a **delta sub-line**, one column per metric. The band is a unit: its internal rhythm is identical on every page that has one, so a change to one tier is a change to all five pages.
_Avoid_: card row, header cards, metric strip

**Delta sub-line**:
The period-over-period comparison under a KPI value — the "getting better or worse" half of the metric, carrying a signed change against the prior window. Colour marks sentiment only where sentiment is unambiguous, and never alone: the sign is always spelled out, so the reading never depends on hue.
_Avoid_: trend line (that is a chart), variance, delta card

**Chrome tier**:
Report text that *frames* the data and can be shortened by editing the report — visual titles, page subtitles, hints, notes, tooltip text, legend series names, table column-header captions. Meets the design canon's readable minimum. See ADR-0012.
_Avoid_: labels, static text

**Dense tier**:
Report text that *is* the data, where shortening the string would mean changing the data — category and axis tick labels, data labels, grid cell values, matrix headers bound to a data column. Carries a lower hard floor than **chrome tier**, deliberately: where size and information collide, information wins. See ADR-0012.
_Avoid_: small text, data text

**Semantic text token**:
A theme colour whose job is to tint *text* that states a verdict — `good` / `neutral` / `bad` on a **delta sub-line** or a freshness pill. Held to the 4.5:1 text contrast floor, and free of any colour-separation duty because every use spells the verdict out in words. Deliberately distinct from a **categorical slot**. See ADR-0013.
_Avoid_: status colour, sentiment colour, semantic colour

**Categorical slot**:
One fixed position in the six-entry chart palette (`dataColors`, `categoricalLight`), assigned to a series by order and never cycled. Held to the 3:1 graphical floor plus colourblind separation from its neighbours — a different, partly conflicting standard from a **semantic text token**, which is why the green and amber of each may differ. See ADR-0013.
_Avoid_: data colour, series colour, palette entry

### Identity

**Linked identity**:
A telemetry identity on a personal email address, resolved to the corporate identity of the same person because the two emitted under a shared `session_id` — one Claude Code process, one human re-authenticating. Resolved for **visibility only**: the two keep separate `dim_user` rows and separate facts, and the personal one still reads `"Off-roster identity"` on Data Health. The link exists so `OrgScope` admits the personal identity into that person's management chain, which it otherwise cannot, there being no HR row on a personal address. Derived under guards (two shared sessions, exactly one corporate partner, never corporate-to-corporate) or supplied by the operator when no shared session exists; a human-supplied link always outranks a derived one. See ADR-0011.
_Avoid_: merged user, alias account, identity resolution

**Process owner**:
The OS account a Claude Code process runs under — `process.owner`, promoted onto both raw tables (#353). A Claude Code **Desktop / Cowork** resource attribute only: the CLI never emits it, so it reaches ~0.4% of records and 5 of the 20 emitting **seats**, and its absence says nothing about the seat — it is emitter behaviour, not evidence. Where it is present and disagrees with the local-part of an ITWorx `user_email`, `refresh_all()` records an `owner_email_mismatch` **DQ finding** at session grain (#372): one person may be emitting under another's account. An *observation*, never a control — being blind to the surface the rest of the fleet works on, it cannot clear a session it never sees. Personal addresses are excluded rather than reported: a `First.Last` machine account can never equal one, and that reading belongs to **linked identity** (ADR-0011).
_Avoid_: process user, machine owner, account-sharing check

**Scoping address**:
The address an identity is **secured** as, distinct from the address it **emits** as — `dim_user[rls_email]`. Its own address for everyone except a **linked identity**, which carries its corporate counterpart's. Both relationships out of `dim_user` key on it, so the `OrgScope` predicates themselves never mention linking (ADR-0011).
_Avoid_: canonical email, primary email

**Unattributed telemetry**:
A metric or event whose `user_email` is NULL, bucketed by `marts.email_bucket` into the single `'(unknown)'` identity. Unattributed rows keep their facts, so volume is measurable; what is lost is the person. Because every NULL-email row collapses into one `dim_user` row, the *number of people* behind unattributed telemetry is not derivable from the marts — only its volume. Volume is grain-dependent and the two surfaces that report it differ on purpose: the `unknown_email` **DQ finding** counts raw rows, while the Data Health headline counts the mart rows they aggregate into.
_Avoid_: unknown email users, anonymous user, orphan telemetry

### Licensing

**Seat**:
A licensed Claude subscription entitlement assigned to one person, at a tier, within an **Anthropic organization**. The licensed-population denominator, an order of magnitude larger than the instrumented one (the first drop: 184 seats against 17 **tracked machines**), which is exactly why seats and machines need separate names. Sourced from IS's roster, never from telemetry. See ADR-0009.
_Avoid_: licence, user (a seat may never emit)

**Untracked seat**:
A **seat** whose holder's email has never appeared in telemetry — the complement of the instrumented population (164 of 184 at the first drop, on an all-time basis; the exec coverage card's remainder is the same count bounded on `first_seen` and so moves with the date slicer), carried as `dim_seat_current[telemetry_status]` and listed on the Data Health worklist, longest-held first, so it reads as a rollout list for IS rather than an adoption percentage. Named for the observation, never the cause: today it means the **installer** has not reached that machine, and once rollout completes the identical column will mean genuinely idle, with no code change to mark the shift. Coverage — instrumented over licensed — is the only ratio that divides by the licensed population; every ratio with a telemetry-derived numerator divides by instrumented seats instead (ADR-0009).
_Avoid_: idle seat, unadopted seat, silent seat

**Roster drop**:
One roster file as received from IS, identified by its operator-supplied as-of date — a current-state snapshot with no person-level status column and no export timestamp. Landed immutably in `ref` (`roster_drop` + `seat_roster_snapshot`, assignment grain) by `tools.roster_load`; seat history is derived from the accumulated drops, never merged at load time. Absence from a newer drop is revocation. Since the 2026-08-02 drop the file also carries **revocation events** (ADR-0024) — which subscription was revoked, and when — but they cover a minority of removals and do not displace absence.
_Avoid_: roster import, seat file

**Revocation event**:
IS's record that one subscription was revoked on one date — `revoked_subscription_raw` + `revoke_date` on `ref.seat_roster_snapshot`, at assignment grain, first carried by the 2026-08-02 **roster drop** (ADR-0024). Per *subscription*, not per person: most are Github Copilot revocations, and a person can hold a revocation record while still holding a Claude subscription. It exact-dates a **seat interval**'s close only when the person is left holding no Claude subscription at all; otherwise it is inert.
_Avoid_: revocation status, seat closure (the closure is the derived interval boundary, not this record)

**Seat interval**:
A contiguous period over which a **seat**'s tier and Anthropic organization were unchanged — the derived SCD2 record, one row of `marts.dim_seat` (#293). Half-open `[valid_from, valid_to)`, with `valid_to` null while the seat is open, so a tier change closes one interval exactly where the next opens and no **seat-day** is counted twice. A person's intervals need not be contiguous with each other, though: a **revocation event** can close a Claude seat before the drop that reported it, leaving a genuine seatless gap (ADR-0024). Each boundary carries a `valid_from_basis` marker: source-dated (from IS's assignment date) or observation-dated (from the drop's as-of date, all that exists for a closure IS records no revocation date for).
_Avoid_: seat history row, validity period

**Seat-day**:
One date on which one **seat** was open, at the tier and **Anthropic organization** in force that day — one row of `marts.fact_seat_day` (#293). The unit that makes point-in-time licensing structural: licensed seats on a date is a row count under the date filter, and seat-days by tier is a sum, so no measure carries interval logic.
_Avoid_: licence day, seat count row

**Anthropic organization**:
The Anthropic org boundary a **seat** belongs to — IS's `Team` column, stored as `anthropic_org_name` (`ITWorx`, `ITWorx2`) and mapping to telemetry's `organization_id`. Not a development team and never joined to a department; ITWorx holds two because a seat cap was reached.
_Avoid_: team, tenant

### Deployment

**Tracked machine**:
A developer machine with Claude Code telemetry configured (managed settings + wrapper). The scale unit for infra sizing, token distribution, and fleet config. Distinct from developer — one dev may have several tracked machines; reporting keys on `user.email`.
_Avoid_: endpoint (for the entitlement, say **seat** — the two are distinct, not synonyms)

**Installer**:
`install.ps1` — the idempotent, **drift-repairing** per-machine setup script. Each tick it verifies real state (installed files — `managed-settings.json` including the wrapper `statusLine.command`, plus the wrapper itself — machine-scope env vars, and user-settings telemetry keys) and repairs any drift; a clean machine no-ops fast. It leaves each user's own `settings.json` statusline untouched (the wrapper resolves it at runtime, ADR-0003). It **checks** for Node.js but never installs it (the LTS MSI is an IS prerequisite, issue #31); because the statusline is delivered through managed settings, it self-heals the moment Node appears with no install-time action. IS pushes it fleet-wide via their managed tool on a 90-minute cadence; the distribution mechanism itself is out of our scope, the script is ours. `build-installer.ps1` bakes the collector endpoint + fleet token + wrapper into a **single self-contained `install.ps1`** (the only file handed to IS) and **stamps** it (`SHA256(wrapper + managed-settings + schema version)`), so a rotated token forces every machine to re-converge. The token lives only in the gitignored `.env.<env>` and the gitignored built artifact — never the repo.
_Avoid_: deployment script, rollout tool

**Parallel cutover**:
The environment currently serving the report stays live as fallback until the adoption report completes its first successful Power BI refresh from the **production** Azure Postgres; only then is the old one decommissioned. That environment is **interim** — the POC half of the arrangement was surrendered early for cost (ADR-0016) once it had no writer and no reader, leaving interim, which carries the mapped pilot history (ADR-0006), as the thing a bad prod cutover falls back to. See ADR-0004 and ADR-0016.

**Flip watermark**:
Per **seat**, the timestamp of that seat's first **production** row — the moment its **tracked machine** started emitting to prod. It is the upper bound on what the interim→prod copy moves, and what makes the copy safe to re-run: a copied row becomes production's new minimum for that seat, so the next run's window is empty and duplicates need no delete to prevent them. `raw.*` records no provenance, so a bound on the window alone would have had to delete production's own post-flip rows and could not restore them. Derived from production itself (`MIN(ts)` per `user_email`), never recorded, and computed per table because `raw.metrics` and `raw.events` name their event time differently. Per seat rather than per machine because no column identifies a device. See ADR-0020.
_Avoid_: cutover timestamp, flip time (a single fleet-wide instant — the flip is staggered, one watermark per seat)

**Ingest repoint**:
Retargeting **interim**'s sink at production's database and reservoir, so telemetry arriving at interim's collector endpoint lands in production. A **tracked machine** whose **installer** was never re-pushed therefore reaches production without being touched — interim's endpoint and bearer token are unchanged. It is what makes interim **write-quiet** by construction rather than by an operator's assertion, and it gives an unflipped **seat** a **flip watermark** so the ordinary interim→prod copy moves that seat's backlog with no special case. See ADR-0021.
_Avoid_: dual-write (that is a fleet-side second exporter endpoint, rejected in ADR-0020), failover

**Write-quiet**:
Interim provably gaining no new rows — `now() - MAX(meta.processed_batches.processed_at) >= 24 hours`, a server-side ingest clock rather than the client-supplied event time a skewed laptop or a late flush can backdate. The precondition for the **terminal sweep**, and a property of the topology after the **ingest repoint**, not a claim about the fleet. See ADR-0021.
_Avoid_: quiet, idle, drained (each reads as "nobody is working", which is the heuristic this term exists to replace)

**Terminal sweep**:
The one-time copy of an entire `[2026-07-17, ∞)` window for a **seat** that has no production row at all — a machine that never emits again. Run once interim is **write-quiet**, so its right edge is fixed; a seat is excluded the moment it has any production row, which is what keeps the sweep safe to re-run. Everything the **ingest repoint** can reach is handled by the ordinary **flip watermark** copy instead. See ADR-0021.
_Avoid_: backfill (that is ADR-0006's schema-v1→v2 mapping, a different operation), catch-up

**Cutover shortfall**:
Per **seat** and per table, how many of **interim**'s rows above the floor **production** demonstrably lacks — `sum(max(interim - production, 0))` over UTC days, so a production surplus on one day never cancels a shortfall on another. The honest measure of what the cutover still owes, because the copy's own "held at or above a **flip watermark**" count conflates three populations: rows already copied, rows a returning seat's collector replayed straight into production, and rows genuinely missing. Nothing is ever deleted from interim and a copied row collapses that seat's watermark onto itself, so all three read identically in the buckets. A lower bound and a detector, never a recovery cursor — `raw.*` has no primary key, so it says how many rows are missing, never which. See ADR-0021.
_Avoid_: held rows, stranded count (the first names the bucket that cannot make the distinction; the second asserts a cause a count cannot establish)

**Azure prod stack**:
The production environment: a second Azure resource group — IS-provisioned but empty, in an ITWorx subscription — holding a Postgres Flexible Server (public endpoint) plus an Azure Container Apps environment running the collector + sink in one Container App. IS grants RG Contributor only; Ahmed deploys all of it, Postgres included, via Bicep (ADR-0004).
