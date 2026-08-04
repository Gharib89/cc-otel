# Canonical definitions extend to plain views and functions

**Status:** accepted. Amends ADR-0008 (canonical mart definitions + generated migrations).
Scope settled with Ahmed on 2026-08-04 (#426; architecture review candidate 1).

ADR-0008 gave every `marts` materialized view exactly one canonical body on disk
(`db/views/marts/`), with migrations generated from those files and a bidirectional `--check`
gate. Everything else in `staging` + `marts` stayed on the old regime — the "current" body was
whichever migration last touched it. The cost was measured, not hypothetical:
`staging.stg_seat_interval` existed in 5 physical copies (#422 and #424 each re-pasted its full
body forward), and `marts.refresh_all()` in 20 copies across 10 migrations, every new DQ detector
re-pasting every prior one.

## Decision

The canonical-definition seam covers the **full class**: every view, materialized view, and
function in the `marts` + `staging` schemas has exactly one canonical file, and
`tools.matview_sync --check` proves convergence bidirectionally per class — every live object has
a file, every file a live object, every body byte-equal to the catalog deparse
(`pg_matviews.definition`, `pg_views.definition`, `pg_get_functiondef()` — all deterministic on
the pinned `postgres:16`).

Layout mirrors kind and schema — `db/<tier>/<schema>/<name>.sql`:

- `db/views/marts/` — matviews and marts plain views (kind is read from the catalog, not the path)
- `db/views/staging/` — staging views
- `db/functions/marts/` — marts functions

The tool keeps its name (`matview_sync`) — the check/author/bootstrap skeleton, divergence model,
git-HEAD down-body rule, and throwaway-DB verify loop are kind-agnostic; only the catalog reader
and the migration template vary, held in one per-kind table.

Object names are unique across both schemas and all kinds — the divergence key, the on-disk file
stem, and `--name` resolution all assume it, and the tool enforces it with a hard error rather
than a silent last-write-wins.

## Migration template per kind

A matview migration stays DROP + CREATE (ADR-0008). A plain view or function generates
`CREATE OR REPLACE` with **no DROP**: `stg_seat_interval` has matview dependents, and a
`DROP ... CASCADE` would silently take the marts with it. Consequences, accepted deliberately:

- A structurally impossible replace (column rename/drop/reorder on a view) fails loudly at the
  author-mode throwaway-DB apply; the operator hand-authors that one cascade migration from the
  canonical files, and `--check` proves the end state. No auto-cascade generation — recreating a
  dependency tree correctly is a deep feature for a rare case, and a wrong cascade drops marts.
- The same asymmetry exists on the way down: a view's `migrate:down` is `CREATE OR REPLACE` of
  the previous body, so the down of a column-*adding* migration is a column-*dropping* replace,
  which Postgres forbids. It fails loudly if ever run; the escape hatch is the same. Function
  downs have no such constraint.

Render templates: a marts view or matview carries `GRANT SELECT TO cc_otel_read`; staging objects
and functions have no grant to carry. A function's file embeds `pg_get_functiondef()` verbatim,
terminated with `;`.

## Consequences

- The next `stg_seat_interval` change is a one-file diff plus a generated migration — never a
  250-line body copied forward. A new DQ detector edits `db/functions/marts/refresh_all.sql`.
- The 20 historical `refresh_all` copies stay in the migration history (history is immutable);
  they simply stop growing.
- `db/views/staging/` and `db/functions/` join `db/views/marts/` in the sqlfluff exclusion —
  catalog-deparse dumps are not sqlfluff-clean by construction (#263).
- No migration ships with the extension itself: bootstrap only extracts live bodies to disk; the
  first generated migration happens the next time one of these objects changes.
