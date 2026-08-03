# Report ownership leaves the repo: the host is a parameter, the tree is an archive

**Status:** accepted — **amends ADR-0004** (on-disk `.pbip` is the report's source of truth) and
**ADR-0014** (one workspace Admin; handover by semantic-model takeover, not standing membership).
Implemented by #247 (the repoint + this ADR) and the handover issue it spawns. Decided 2026-08-03.

#247 was scoped as a mechanical repoint: swap `ccotel-pg-interim` for `ccotel-pg-prod` across 21
partitions, refresh in Desktop, republish. Two facts changed what the ticket actually is.

First, **the report has a new owner**: Mohamed Atallah (`Mohamed.Atallah@itworx.com`) takes over the
Power BI layer permanently, and works in Power BI Desktop and the Service — not in this repository.
That makes ADR-0004's "on-disk PBIP is the source of truth" false the moment he changes anything,
and it makes ADR-0014's "handover happens by semantic-model takeover, not standing membership" a
description of a handover that already happened rather than a policy about the future.

Second, **the flip is not the last environment change this model will see**. ADR-0021 lands the
ingest repoint (#410) *after* this one, deliberately — "before it, the published report still reads
interim and the repoint would flatline it" — and the interim database survives for a short window
afterwards. A 21-file find/replace is exactly where one site gets missed and a single table silently
keeps reading interim, and it is a change a Service-only owner cannot make at all.

## Decisions

- **The server and database are M parameters, not literals.**
  `powerbi/cc-otel-report.SemanticModel/definition/expressions.tmdl` declares `PgHost` and
  `PgDatabase` (`IsParameterQuery=true, Type="Text"`), and all 21 partitions read
  `PostgreSQL.Database(#"PgHost", #"PgDatabase")`. Both default to production
  (`ccotel-pg-prod.postgres.database.azure.com`, `cc_otel`), so the archived tree matches what is
  published.

  Three published facts make this the cheaper mechanism rather than a nicety. Parameterized sources
  stay refreshable — "queries that reference Power Query parameters can also be refreshed"
  ([refresh-data](https://learn.microsoft.com/power-bi/connect-data/refresh-data#refresh-and-dynamic-data-sources)),
  and the dynamic-data-source ban that sentence sits under does not apply. Parameter *values* are
  editable in the Service (Semantic model settings → Data access → **M parameters**,
  [settings pane](https://learn.microsoft.com/power-bi/connect-data/service-semantic-model-settings-pane#what-you-can-do-in-the-settings-pane)),
  so an environment move is a value edit by the owner, with no Desktop, no `.pbip`, and no git. And
  the Service's separate "switching data sources using dynamic M query parameters isn't supported"
  restriction is about the DirectQuery consumer-bound parameter feature, not static text parameters
  in an Import model.

  The trap it does not remove: **data-source credentials are bound per server**, so the new host
  arrives uncredentialed and the first refresh after any value change fails until credentials are
  re-entered. That is a step in the runbook, not an argument against the parameter.

- **The Azure SQL HR source stays a literal.** `vw_UserBasicInfo` lives on `itxdatainteg-prod`, which
  is IS-owned and does not move between our environments. Parameterizing it would add a knob whose
  only correct value is the one already there.

- **The repoint ships before history converges, with no on-report caveat.** Production is missing the
  unflipped seats' backlog (91,769 metrics / 103,355 events across ~15 seats, measured 2026-08-03 —
  ADR-0021) and interim is missing the flipped seats' post-flip rows, so both copies are partial and
  the flip picks which gap the report shows. Production is chosen because ADR-0021 requires this
  order, because production is the copy that converges and interim is the copy scheduled for
  deletion, and because #410 plus the next `tools.cutover_copy` run closes the gap in days.

  The accepted consequence is visible: fleet totals for `[2026-07-17, flip)` **rise** as the backlog
  lands, so a manager who quotes a number this week sees a different number next week with nothing on
  the canvas explaining it. A temporary banner was considered and rejected — it would have to be
  removed by the new owner, on a schedule tied to tickets he does not track. The explanation lives in
  `powerbi/HANDOVER.md` instead, where the person fielding the question can read it.

- **The report's rollback window is #247 → #410, and #410 is what gates it.** Pointing `PgHost` back
  at interim is only meaningful while interim still *receives* telemetry; once its sink writes to
  production, interim is a frozen database that also misses every flipped seat. So the handover issue
  blocks **#410**, not #248's RG deletion — the gate belongs on the ticket that ends the window, and
  #248 keeps only the gates ADR-0020 and #409 already give it.

- **`powerbi/` becomes a frozen archive of the last repo-authored state.** The Service is the source
  of truth for the report from this change onward. `ci-powerbi.yml` stays: it costs nothing on a tree
  nobody edits and it trips if someone edits it anyway. `powerbi/CLAUDE.md`'s routing table is
  rewritten from "how to author here" to "do not author here", because the failure mode is not a
  human — it is an agent finding a PBIR file and helpfully fixing a visual nobody will publish.

  This is scoped to the report. Everything else in the repo keeps "everything is a migration" and
  on-disk authority; only `powerbi/**` loses it.

- **Two workspace Admins, both unscoped.** Mohamed needs Admin to own the semantic model and publish
  the app; the pipeline owner keeps Admin to diagnose freshness and DQ questions that are not Power
  BI's fault. ADR-0014's single-Admin count therefore becomes two, and its "no standing membership"
  intent is abandoned rather than reinterpreted. The cost is exact and unchanged in kind: RLS "doesn't
  apply to workspace Admin, Member, or Contributor roles", so this is a second identity that reads all
  184 roster addresses unscoped. Consumers are unaffected — they reach the report through the app and
  hold no workspace role (ADR-0014), so `OrgScope` still applies to every audience member.

- **The owner is Service-only: no VPN, no `psql`, no Entra grant on production Postgres.** The Service
  reaches both sources over cloud connections with no gateway (ADR-0014), so ownership needs nothing
  else. He receives the existing `cc_otel_read_user` and `AZURE_DB_*` credentials out of band — never
  through this repository, which is public (ADR-0018). Minting a dedicated read login was rejected:
  one consumer, and it would cost a migration, a `bootstrap.ps1` change, and a secret fan-out to
  isolate a password that two people would hold either way.

- **Escalation splits at the database boundary.** Power BI-side failures — expired credentials, refresh
  binding, workspace, app, visuals — are the report owner's. Everything from `marts` down — sink,
  `pg_cron` `marts.refresh_all()`, DQ findings, mart definitions — stays with the pipeline owner.
  Refresh-failure notifications go to the semantic-model owner **plus** the pipeline owner as an
  additional contact, so a credential expiry and a stalled `refresh_all()` both reach the person who
  can fix them without a triage hop.

## Considered options

- **Find/replace the 21 literals, no parameters.** Rejected on the second environment change, not the
  first: it is a repo edit plus a Desktop republish, which a Service-only owner cannot perform, and it
  is the shape of change that leaves one table pointed at the old host.

- **The new owner performs the flip himself** (Desktop → Data source settings → Change Source, or a
  parameter edit in the Service). Rejected. #247 carries repo-side documentation changes that
  `CLAUDE.md` requires in the same change, and a brand-new owner structurally cannot ship them; his
  first act should not be a migration whose blast radius he cannot yet judge.

- **Keep the on-disk tree authoritative via periodic re-export.** Rejected: nothing in CI enforces the
  sync, so the divergence is silent until someone diffs, and the artifact most likely to be stale is
  the one a future agent would trust.

- **Keep exactly one Admin** by stepping the pipeline owner down to Viewer. Rejected: it minimises the
  RLS surface at the price of routing every report-side diagnosis through the one person who does not
  own the pipeline.

- **Gate the flip on convergence** (#410 plus a `cutover_copy` run). Rejected because ADR-0021 fixes
  the opposite order — the ingest repoint would flatline a report still reading interim.

## Consequences

- **The next report change needs a decision, not just an edit.** With the tree frozen, a visual or
  measure change is authored in Desktop by the owner and does not come back to git. Re-establishing
  on-disk authorship later means un-freezing deliberately and re-exporting from whatever the Service
  holds — the repo's copy will not be a valid base by then.

- **`ci-powerbi.yml`, the `powerbi-ship` skill, and `docs/agents/powerbi-tooling.md` describe a lane
  with no traffic.** They are kept, not deleted: the skill and tooling notes are the recovery path if
  authorship ever returns, and the CI gate is the tripwire that makes an accidental edit loud.

- **A future owner change costs a takeover, not a repo step.** Semantic-model ownership transfers in
  the Service ([Take over](https://learn.microsoft.com/power-bi/connect-data/service-datasets-understand#semantic-model-ownership)),
  and credentials are re-entered by whoever takes it — which is also why each owner needs the
  data-source passwords in hand.

- **Two writers, one report, one unexplained wobble.** Fleet history for `[2026-07-17, flip)` moves
  once more when #409's terminal sweep lands (ADR-0021 already records this for production's
  aggregates). The report shows it; only the runbook explains it.
