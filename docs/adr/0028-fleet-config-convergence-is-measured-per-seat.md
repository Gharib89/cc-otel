# Fleet-config convergence is measured per seat, by a stamp the telemetry carries

**Status:** accepted — companion to **ADR-0027** (which measures one front door, and cannot name
seats) and an extension of **ADR-0003**'s wrapper contract. Implemented by #432. Decided 2026-08-06.

`install.ps1` repairs the **disk** on IS's 90-minute cadence. Claude Code reads `OTEL_*` **once, at
process start**, and a Windows machine-scope environment-variable change never reaches a running
process. So after any installer re-push — new front door, rotated token, new wrapper, schema bump —
the fleet splits into converged and stale processes, and until now no signal distinguished them.
Observed concretely on 2026-08-03: seats still POSTing to interim's front door three days after the
ingest repoint, discovered only because one person reported it (#431, ADR-0027). ADR-0027 closed the
door-level question — *is anyone still posting here* — and is silent on *which seats*, because a
`401`/`200` count carries nothing identifying.

The material already existed: `Get-InstallerStamp` (`install.ps1`) is
`SHA256(wrapper + managed-settings + installer schema version)`, computed identically at build time
and on the machine, persisted per machine, and already driving per-distro WSL re-convergence. A
rotated token changes the baked managed-settings text and therefore the stamp — exactly the property
convergence needs. It just never left the machine.

## Decisions

- **The stamp travels as an OTel resource attribute.** `install.ps1` writes
  `OTEL_RESOURCE_ATTRIBUTES=installer.stamp=<sha256>` into the managed env block, so every metric and
  event Claude Code's native exporter emits names the config its process is running. No new signal,
  no side channel, no new pipeline: it is curated like any other attribute (`meta.column_registry`),
  and a promotion follows the ordinary rules.

- **Injected at materialization, never baked into the artifact.** The stamp is a hash *over* the
  managed-settings text, so a stamp baked by `build-installer.ps1` would be an input to its own
  digest: the runtime recompute would return a different value, and the attribute would then report a
  stamp neither the install state file nor the WSL stamp map knows. `Invoke-Install` therefore hashes
  the baked payload first and stamps it after — one injection, before anything is materialized, which
  is what puts the same value in the file, the machine-scope env mirror, and the WSL leg.

- **The wrapper reports the disk stamp; the process stamp arrives natively.** Claude Code strips
  `OTEL_*` from the statusLine subprocess (v2.1.128+, `cc-otel-wrapper.mjs`), so the wrapper cannot be
  relied on to see what its parent started with — it emits `installer.stamp` when its env does carry
  one and always emits `installer.stamp_on_disk`, re-read from `managed-settings.json` on every call.
  Divergence is therefore read across the two row sources per seat, not within one record:
  `installer_stamp` (any signal) against `installer_stamp_on_disk` (statusline records only).

- **Both are promoted columns, forward-only.** No `kept_basis` in the closed set honestly fits a
  config hash — it is neither unbounded by nature, constant, collinear, thin, nor redundant with
  anything in the schema — and the burn-down has to be a SQL question. ADR-0017's reservoir replay
  does not apply: a brand-new attribute has no history in the reservoir to replay, so both columns are
  NULL for everything before the re-push that first ships them (ADR-0002's forward-only default).

- **The convergence read is a plain view, `marts.seat_config_convergence`.** Per seat: latest stamp,
  latest disk stamp, when each was last seen, and `is_converged`. Plain, not materialized (ADR-0026
  makes that a first-class canonical definition): it is an ops read against `raw`, it must answer as
  of now rather than as of the last refresh, and it needs no refresh wiring. `is_converged` is
  three-valued — NULL while either stamp is unmeasured, because "not yet reported" is a different
  answer from "stale".

- **A hash identifies a config; it does not order two.** The stamp answers same-or-different only.
  Where ordering is ever needed, `InstallerSchemaVersion` is carried separately; it is deliberately
  not the convergence key, because a token rotation does not bump it.

## Considered options

- **Query the machines instead.** Rejected: the fleet is IS-managed and we have no read channel to
  it. The telemetry pipeline is the only fleet-wide read this project owns, which is the whole reason
  the stamp has to travel as a signal.

- **Emit the installer schema version rather than the stamp.** Orderable, and far too coarse: it is
  bumped only when the wrapper contract or managed-settings shape changes, so a rotated token or a new
  front door — the changes whose convergence most needs measuring — would not move it.

- **Bake the stamp at build time** (the shape #432 first proposed). Rejected on the circularity
  above.

- **Read the parent process's environment from the wrapper.** Rejected: Windows offers no supported
  way to read another process's env, and `NtQueryInformationProcess` is not a statusline's job. The
  native exporter already carries the value.

- **Classify the attribute `kept` and answer convergence from the reservoir.** Rejected: no honest
  kept basis exists for it, and a decommission gate read through a DuckDB notebook is not a gate
  anyone will run.

## Consequences

- **Both columns read NULL until IS re-pushes the installer.** The measurement starts when the fleet
  carries it; a seat that never re-pushes stays NULL, which — read together with ADR-0027 — is itself
  the finding.

- **A seat whose statusline never pushes has an unmeasured disk stamp.** The wrapper throttles to one
  push per five minutes per machine and only pushes when the payload carries `rate_limits`, so
  `installer_stamp_on_disk` is sparser than `installer_stamp`. Convergence then reads NULL, never
  false — the view must not call a seat stale on missing evidence.

- **`is_converged` compares two independent recency clocks.** The process stamp rides every signal;
  the disk stamp rides statusline pushes only, so a seat can hold a *newer* process reading than disk
  reading and read `false` while its machine is in fact converged. That is why the view exposes
  `stamp_seen_at` and `disk_stamp_seen_at` beside the verdict rather than a bare boolean: a `false`
  whose disk reading is much older than its stamp reading is a stale *reading*, not a stale process.
  The guarantee is one-sided — NULL on missing evidence, never a bare `false` — and old evidence is
  the reader's to weigh.

- **#248 Part B gains a companion read.** ADR-0027's measurement says interim's front door is silent;
  this one says which seats are still running the pre-repoint config, so a door that is not yet silent
  has named machines behind it instead of an unbounded tail.

- **On v2.1.161+ the value also arrives as a metric datapoint label**
  (`OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES`, default `true` — `docs/research/`). Harmless: the
  parser merges datapoint attributes over resource attributes, and both carry the same string, so the
  column is written either way and one `resource`/`*` registry row still covers the key (the sweep's
  signal fallback is one-directional by design).

- **The next fleet-config change is measurable with no new work** — which is the point of putting the
  rule in an ADR rather than in the ticket that needed it first.

- **`docs/data-dictionary.md` is not regenerated in the implementing PR.**
  `tools.gen_data_dictionary` reads live profiling stats from a database that already carries the
  columns; against a throwaway container it would zero every other column's stats. It is regenerated
  after the deploy, on the next curation pass.
