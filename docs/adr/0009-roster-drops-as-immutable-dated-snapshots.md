# Roster drops land as immutable dated snapshots; seat history is derived, not merged

**Status:** accepted

The `seat_roster` table feeding the adoption report is fabricated from telemetry (#163): tier is
wrong for real users, "off-roster" is structurally impossible, and the licensed-seat denominator
equals the observed-user count by construction. IS now supplies a real roster by email, roughly
every two weeks, as a manual and therefore irregular process. It is a **current-state snapshot
only** — no status column, no revocation date, no export timestamp; removed seats simply stop
appearing.

Latest-snapshot-wins would make today's numbers right and every historical number wrong: seats
grew from 13 in April 2026 to 184 in mid-July, so applying today's roster to June divides by a
denominator that did not exist yet. Decision log: #290; implementation: #292 (ingest), #293
(derivation).

## Decisions

- **A new `ref` schema holds externally-sourced reference data.** `raw` stays telemetry-only,
  keeping the existing definition of raw tables as telemetry archive and drill source true. The
  roster is the first feed of this class — an install-coverage feed (#296) would be the second —
  so the boundary is reused rather than roster-shaped. `ref` is not granted to `cc_otel_read`:
  Power BI reads marts only.
- **One immutable dated observation per drop, at assignment grain.** `ref.roster_drop` records
  the file (as-of date, filename, SHA-256, row count, ingested-at/-by, notes) and
  `ref.seat_roster_snapshot` holds one row per person per subscription. Grain is
  assignment-level because IS's numerically suffixed `subscription_1` / `assignment_date_1`
  columns signal their export tool can emit a second subscription per person; unpivoting at
  ingest turns that from a migration into a data event.
- **Derived history, not merge-on-ingest.** Seat intervals are derived from the ordered snapshot
  history on every refresh (#293), never merged into a dimension at load time. The ingestion
  process is manual, so drops will not arrive in as-of order; a merge-on-ingest SCD2 would write
  intervals that need hand surgery when a 7/20 drop lands after an 8/01 one. Derivation sorts by
  as-of at refresh time, so arrival order is irrelevant and a late drop self-corrects. It also
  makes policy reversible — the revocation and dating rules will change if IS adds a status
  column (#291) — and volume makes it free: 184 seats over ~26 drops a year is a few thousand
  rows.
- **Every column lands verbatim; unmapped headers are captured into `extra` JSONB.** A new IS
  column is retained from the moment it first appears rather than discarded until we code for
  it. `seat_tier` is normalized to the semantic model's vocabulary (`Claude Standard` ->
  `Standard`) while `subscription_raw` keeps what IS actually sent, so normalization is never
  lossy.
- **Email is the only required column; descriptive columns are tolerated, never validated.**
  Email is normalized to lower/trim — it is the key every consumer joins on, matching the marts'
  existing email keying. A missing tier is a data-quality concern, not a load failure (one such
  row exists in the first drop). The roster's descriptive data is known to be less accurate than
  the HR view and is retained for history only, so no reconciliation against it is performed.
- **Revocation is absence, guarded at load time against truncation.** A seat missing from a
  newer drop is closed immediately. The loader requires `--force` when the row count falls more
  than 10% against the prior drop, when an organization present in the prior drop is entirely
  absent, or when a tier value disappears. A confirmation window (revoke only after two
  consecutive absences) was rejected: it pays permanent latency on every legitimate revocation to
  defend indirectly against truncation, and derived history already provides the recovery path —
  delete the bad drop, refresh, history heals.
- **The operator supplies the as-of date, validated against what the data can prove.** The file
  carries no export timestamp and a filesystem timestamp resets on copy. An as-of earlier than
  the newest assignment date in the file is refused with no override (provably impossible); one
  duplicating or preceding an existing drop is refused without `--force`.
- **Dry run by default, and it prints the resolved host and database first.** Consistent with the
  two other destructive tools in `tools/` (`scrub`, `replay`). Printing the target defuses a live
  trap: the ambient `DATABASE_URL` points at the retired POC server, so the most natural
  invocation would otherwise write HR data into a decommissioned database and report success.
- **No copy of the file is retained.** The snapshot plus the `extra` capture is the archive; the
  hash remains the idempotency key. This is a deliberate exception to the convention that raw
  artefacts land in the blob reservoir (ADR-0005), taken because the roster is a small,
  fully-parsed CSV rather than an evolving payload shape.
- **The derivation lives in one shared view; every seat mart is a thin projection of it.**
  `staging.stg_seat_interval` reads only the `ref` snapshot tables, and `marts.dim_seat`,
  `marts.dim_seat_current` and `marts.fact_seat_day` each project it (#293). A daily-grain mart
  reading an interval mart would be the first violation of `marts.refresh_all()`'s invariant
  that no mart reads another — the invariant its alphabetical catalog loop depends on. Routing
  all three through a view keeps that untouched, at the accepted cost that the view body sits
  outside the mart-definition drift gate, the same exposure the shared mart rule functions
  already carry. Intervals are half-open, so a tier change counts no seat-day twice.
- **`marts.dim_date`'s floor considers the earliest assignment date.** The first drop carries
  assignments 46 days before the earliest telemetry; without the extended floor those daily seat
  rows would have no matching date row and would vanish from every date-filtered measure —
  discarding exactly the history the source-dating rule recovers. The visible consequence is a
  flat run-in on unfiltered trend visuals over a period with seats but no instrumentation, which
  is true and informative; the synced relative-date slicer already defaults the window.
- **The roster is additive.** It does not re-base `marts.dim_user`, which stays telemetry-only:
  extending it to the union of telemetry and roster people would silently move every distinct-user
  count from 20 to 184, re-basing exactly the measures that must stay on tracked members.

## Consequences

- Byte-exact re-parse after a loader defect is not possible from our systems; the operator retains
  the source emails out of band.
- Closure and tier-change boundaries are observation-dated where the source supplies no date, so
  worst-case error is half the drop cadence (~1 week). Every derived interval carries a
  `valid_from_basis` marker (#293) so the inferred share of the timeline is measurable.
- A plausible-looking bad export dropping a handful of people passes the guards; it is caught
  after the fact by the telemetry-after-close finding (#293) — Anthropic enforces licensing
  server-side, so a genuinely revoked seat cannot emit.
- If IS adds a status or revocation column (#291), it lands in `extra` on the next drop with no
  code change, and promoting it is a column plus a derivation edit — not a backfill.
- A drop landing between hourly refreshes would leave the seat marts stale, so `roster_load`
  refreshes them on write, plus `dim_date`, whose floor that same write can move. Every other
  telemetry mart is left to `marts.refresh_all()`.
