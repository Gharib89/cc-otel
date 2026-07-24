# Mart bodies live once as canonical files; migrations are generated, not hand-written

**Status:** accepted

"Everything is a migration" (CLAUDE.md) means a mart's DDL only ever reached the DB
through a dbmate migration. It said nothing about where the mart's *current* body
lives, so it lived in whichever migration last touched it: to read `fact_session_daily`
you had to find the newest of its 7 physical `CREATE MATERIALIZED VIEW` copies scattered
across the migration timeline, and a redefinition was a hand-copied DROP+CREATE that
silently drifted from the intended body. There was no single source of truth for "what
is this mart, today". Decision log: #254; implementation: #263.

This ADR does not weaken "everything is a migration" — the generator still emits ordinary
dbmate migrations, and `db/schema.sql` is still the pg_dump-generated truth. It adds a
layer *above* migrations for authoring.

## Decisions

- **One canonical file per mart.** Each mart body lives exactly once as
  `db/views/marts/<slug>.sql` — header + `CREATE MATERIALIZED VIEW` + its unique index +
  the reader `GRANT`. This file is the source of truth for the mart's current shape; the
  migration timeline is its lineage, not its definition.
- **Migrations are generated, never hand-pasted.** `tools/matview_sync.py --name <slug>`
  renders the dbmate migration from the edited canonical file — `migrate:up` is
  DROP+CREATE+index+GRANT of the new body; the tool then normalizes the file to
  `pg_matviews`' own deparsed form so any hand-edit style still converges. Mirrors the
  `spec_sync` author/gate contract.
- **`migrate:down` embeds the previous body from git HEAD — no `_vNN` files.** The down
  body is the same canonical file at git HEAD, embedded verbatim (trailing whitespace
  trimmed). Rejected keeping versioned `<slug>_vNN.sql` files: git history already *is* the
  version ladder, and parallel `_vNN` files reintroduce the many-physical-copies problem
  this ADR exists to kill.
- **Bidirectional `--check` gate.** On a from-zero DB, `matview_sync --check` regenerates
  every canonical file from the live mart and full-string-compares against disk: flags a
  live mart with no file, a file with no mart, and a body edited without a migration. Wired
  into `integration.yml` and `scripts/ship/local-gate.sh`, same as the schema-drift gate.
- **Bootstrap all existing marts at once, not incrementally.** All 16 marts got canonical
  files in the first change. A partial gate (some marts covered, some not) rots — the
  bidirectional check only holds meaning when every mart is in.
- **Shell-free author path.** `--name` normalizes via an ephemeral Docker Postgres
  (psycopg), not by shelling to `dev-migrate.sh` — Python's `subprocess` `bash` resolves to
  WSL on Windows and can't find `dbmate`/`pg_dump`. `db/schema.sql` regeneration stays with
  its owner, `dev-migrate.sh`.

## Consequences

- A mart's current body is one `cat db/views/marts/<slug>.sql` away; its history is
  `git log` on that file. No more hunting the newest of N migration copies.
- Authoring a mart change is: edit the canonical file, run `--name <slug>`, run
  `dev-migrate.sh` to regenerate `schema.sql`. Hand-writing a mart migration is now a gate
  failure, not a convention violation.
- `refresh_all()` stays catalog-driven off `pg_matviews` (#274) — orthogonal to this ADR.
- The ephemeral-Postgres helper is duplicated from `spec_sync`; extraction tracked in #275.
