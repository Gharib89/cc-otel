# Mart Definition Management: Canonical Matview Bodies Under a Migration Discipline

**Date:** 2026-07-24

**Research question:** What prior art exists for keeping one canonical CURRENT definition per Postgres materialized view while every change still lands as a migration? Today each matview change is a hand-written `DROP MATERIALIZED VIEW` + full `CREATE ... AS` + unique index + reader `GRANT` inside a dbmate migration (e.g. `db/migrations/20260723074556_coalesce_unknown_email_in_facts.sql`, which carries grain, index, and grant forward by hand for six facts, and hand-restores each prior body in `migrate:down`), so the "current" body of a matview lives in whichever migration last redefined it. `marts.refresh_all()` (`db/migrations/20260713170012_create_marts_refresh.sql`) additionally hard-codes a `TEXT[]` of 14 matview names. Four sub-questions: (1) definition-files + generated migrations prior art, (2) factoring shared SQL rules into functions referenced by matview bodies (Postgres 16 inlining semantics), (3) deriving the refresh list from catalogs instead of a hand-edited array, (4) anything dbmate-native.

**Method:** Every claim traces to a primary source — official tool READMEs/docs, the tools' own GitHub repos/issues/CHANGELOGs, postgresql.org 16 docs, the PostgreSQL wiki, and the PostgreSQL source tree (`REL_16_STABLE`) where the docs are silent. The two repo migrations named above and `tools/spec_sync.py` were read directly for local grounding. GitHub issue searches ran via `gh` on 2026-07-24. Anything not confirmed against a primary source is flagged **UNVERIFIED**.

---

## TL;DR — verdicts

| Approach / tool | Verdict for cc-otel | Why (one line) |
|---|---|---|
| Versioned definition files + generator (thoughtbot/scenic pattern) | **Adopt the pattern** (port, not the gem) | Canonical body per version on disk; DOWN body = the previous version file; matview + index-reapply + concurrent refresh all first-class |
| graphile-migrate `current.sql` | Pattern informs, tool skip | Iterate-in-one-file ergonomics, but roll-forward only (no down) and it replaces dbmate |
| sqitch `rework` | Skip (tool swap) | Same "previous file kept on disk" insight via `@tag` copies, but means abandoning dbmate |
| dbt `materialized_view` materialization | Skip | The strongest canonical-current-body precedent, but abandons migrations entirely; a SQL-text change alone triggers only a REFRESH — recreation needs `--full-refresh` |
| migra / schemainspect diffing | Skip | Diffs matviews, but officially deprecated |
| sqldef (psqldef) declarative | Skip | Matview support exists (since v0.12.5) but it replaces dbmate and auto-generates destructive DDL |
| Atlas (ariga/atlas) | Skip | Postgres matviews (and views/functions) are paywalled behind Atlas Pro |
| django-pgviews-redux | Pattern only | Definitions-in-code + sync-on-migrate, but no versioning and no down |
| Shared SQL functions inside matview bodies | **Adopt narrowly** | Safe if the function is a single-expression `LANGUAGE SQL` scalar that meets the inlining conditions; non-inlined default-labelled functions serialize `REFRESH` (user functions default `PARALLEL UNSAFE`) |
| `BEGIN ATOMIC` (new-style) function bodies | **Adopt for new shared functions** | Parsed at definition time, dependencies tracked, and still inline-eligible (PG16 source handles `prosqlbody`) |
| `pg_matviews`-driven refresh loop | **Adopt** | Schema-filtered catalog loop kills the forgotten-matview drift risk; pg_depend topo sort only needed if matview-on-matview ever appears |
| dbmate-native support | **None — confirmed** | No repeatable migrations, hooks, view files, or diffing; the pattern must be a generator, à la the repo's existing `tools/spec_sync.py --name` |

---

## 1. Definition files + generated migrations

### 1.1 thoughtbot/scenic (Ruby) — the reference implementation of the pattern

Source: <https://github.com/thoughtbot/scenic> (README).

- **Versioned definition files.** Every view body lives at `db/views/<name>_v<NN>.sql`. `rails generate scenic:view search_results` creates `db/views/search_results_v01.sql` plus a migration calling `create_view :search_results`. Re-running the generator detects the existing view, copies v01 to `search_results_v02.sql` for editing, and emits a migration calling `update_view :search_results, version: 2, revert_to_version: 1`.
- **DOWN body = the previous version file, kept on disk forever.** `revert_to_version: 1` makes the down migration re-read `search_results_v01.sql` from `db/views/` — no SQL duplicated into the migration file itself. `drop_view :search_results, revert_to_version: 2` works the same way. This is the cleanest published answer to "down migrations should restore the previous body": all historical bodies stay on disk as numbered files, and the migration references them by version number.
- **Materialized views are first-class.** `--materialized` generates a matview; updates are drop+recreate (Postgres has no `CREATE OR REPLACE MATERIALIZED VIEW` — the PG16 reference page has no `OR REPLACE` form: <https://www.postgresql.org/docs/16/sql-creatematerializedview.html>). Scenic's README states indexes "will be automatically re-applied when views are updated" — it snapshots the matview's indexes before the drop and re-creates the ones still valid after. Concurrent refresh is supported (`Scenic.database.refresh_materialized_view(name, concurrently: true)`, requiring a unique index — same constraint `marts.refresh_all()` already satisfies), plus `cascade: true` to refresh dependent matviews in order, and a `--side-by-side` update strategy that builds the new version under a temporary name, copies indexes, refreshes, then atomically renames — avoiding the read outage of drop+recreate.
- **What it does NOT carry forward:** grants. Scenic has no grant handling; the repo's `GRANT SELECT ... TO cc_otel_read` per matview would still need to live in the generator or a `DEFAULT PRIVILEGES` migration.

### 1.2 graphile-migrate — the idempotent "current migration"

Source: <https://github.com/graphile/migrate> (README).

Developers iterate in `migrations/current.sql` ("New migrations are composed within 'the current migration'"), re-executed on every save by `graphile-migrate watch`; `graphile-migrate commit` "commits the current migration into the `committed/` folder, resetting the current migration" — i.e. the working file is archived as a numbered migration and emptied. Reversibility is explicitly rejected: "roll-forward only — maintaining rollbacks is a chore, and in 10 years of API development I've never ran one in production." Function/view changes are handled by idempotent DDL (`DROP ... IF EXISTS` then `CREATE`, or `CREATE OR REPLACE`). For matviews that means every `current.sql` touch of a mart is a full drop+create anyway — same mechanics as today, minus the down body. The transferable idea is the *workflow* (edit one canonical file, tool archives it into the numbered history), not the tool.

### 1.3 sqitch `rework` — one file per object, tagged copies as history

Source: <https://sqitch.org/docs/manual/sqitch-rework/>.

Sqitch keeps one deploy/revert/verify script per change (i.e. per object); `sqitch rework` requires that "a tag must have been applied to the plan since the previous instance of the change," then "copies the files for the existing change. The new files are named with the tag that comes between the changes, and serves as the file for the original change. This leaves you free to edit the existing files." So the canonical file stays put and editable; the archived copy carries the `@tag` suffix — structurally identical to scenic's version files, with the version number replaced by a release tag. Reworked changes must be idempotent (either instance runnable any number of times with the same outcome). Already rejected as this repo's migration runner in `docs/research/dev-tooling-stack.md` ("more machinery / wrong paradigm"); rework doesn't change that verdict, but its file model independently validates the "previous body stays on disk under a derived name" design.

### 1.4 migra / schemainspect — schema diffing, deprecated

Sources: <https://github.com/djrobstep/migra>, <https://github.com/djrobstep/schemainspect>.

migra's README opens with the deprecation notice verbatim: "This project is officially deprecated, but its functionality has recently risen like a phoenix from the ashes in [results](https://github.com/djrobstep/results)" (last release 3.0.1663481299, 2022-09-18). Its inspection layer, schemainspect, does cover the objects this repo cares about — its README states it "Inspects tables, views, materialized views, constraints, indexes, sequences, enums, functions, and extensions." So a diff-driven generator (desired schema in files → diff against a from-zero DB → emit migration) *was* viable prior art for matviews, but the tool is unmaintained. Skip; note only that "diff a from-zero DB against the definition files" is exactly what `tools/spec_sync.py` already does for columns, without any external diff engine.

### 1.5 sqldef (psqldef) — declarative, matview-capable, wrong paradigm here

Sources: <https://github.com/sqldef/sqldef>; CHANGELOG <https://github.com/sqldef/sqldef/blob/master/CHANGELOG.md>.

psqldef gained "Initial support of materialized views" in v0.12.5 (closing issue [#262](https://github.com/sqldef/sqldef/issues/262)), matview indexes in v0.12.7 ([#265](https://github.com/sqldef/sqldef/issues/265)), `DROP MATERIALIZED VIEW` support in [#499](https://github.com/sqldef/sqldef/pull/499), schema-qualified matviews in [#655](https://github.com/sqldef/sqldef/pull/655), and `WITH [NO] DATA` in v3.6.1 ([#921](https://github.com/sqldef/sqldef/pull/921)) — so the feature is real and still receiving fixes as of late 2025. But sqldef is a full declarative apply tool ("Idempotent schema management"): it *replaces* the migration runner and generates DDL at deploy time, which conflicts with both dbmate and the schema-drift gate's "migrations are the source of truth" premise. Skip as a tool; its CHANGELOG is useful evidence that auto-diffing matviews is tractable.

### 1.6 Atlas (ariga/atlas) — matviews behind the Pro paywall

Sources: <https://atlasgo.io/hcl/postgres>, <https://atlasgo.io/inspect>, <https://atlasgo.io/declarative/apply>.

Atlas models a materialized view as a `materialized "name" { ... }` HCL block, and supports `WITH NO DATA` on Postgres — but the docs state materialized views (along with plain views, functions, triggers, sequences) "are available to Atlas Pro users" for both `schema inspect` and `schema apply`; the free tier manages only schemas, tables, indexes, and constraints. A paid dependency for exactly the objects this research is about. Skip.

### 1.7 django-pgviews-redux — definitions in code, sync on migrate, no down

Source: <https://github.com/mikicz/django-pgviews>.

View/matview SQL lives as a `sql` class attribute on `pg.View` / `pg.MaterializedView` subclasses; on `migrate`, a post-migrate hook creates or updates the views (disable via `MATERIALIZED_VIEWS_DISABLE_SYNC_ON_MIGRATE`), or run `sync_pgviews --force` manually. Concurrent refresh is supported via a declared `concurrent_index` + `refresh(concurrently=True)`; indexes come from Django's `Meta.indexes`. There is no version history and no down story — the previous body exists only in git. Its autodetector generates migrations only for registering new views and dropping renamed/removed ones; body changes bypass the migration record. That "sync outside the migration ledger" is precisely what the schema-drift gate here forbids. Pattern-only relevance.

### 1.8 dbt — the strongest canonical-current-body precedent, and a warning

Sources: <https://docs.getdbt.com/docs/build/materializations>, <https://docs.getdbt.com/reference/resource-configs/postgres-configs>, and the shipped materialization macro <https://github.com/dbt-labs/dbt-adapters/blob/main/dbt-adapters/src/dbt/include/global_project/macros/materializations/models/materialized_view.sql>.

dbt abandons migrations entirely: each model is one SQL file that always holds the current body, and `dbt run` reconciles the database to it. For `materialized="materialized_view"` on dbt-postgres:

- `on_configuration_change: apply | continue | fail` (default `apply`) governs *config* drift; on Postgres the only monitored config is `indexes`, which dbt applies "without dropping the materialized view" via DROP/CREATE of the indexes ("functions as an ALTER of the materialized view").
- The macro's control flow: relation absent → `get_create_materialized_view_as_sql`; `should_full_refresh()` true (or existing relation isn't a matview) → `get_replace_sql` (recreate); otherwise it checks `get_materialized_view_configuration_changes` and, when none, runs `refresh_materialized_view(target_relation)` only. **A change to the model's SQL text alone therefore does NOT recreate the matview — it only refreshes the stale definition; picking up a new body requires `dbt run --full-refresh`.** (The macro is the authority here; the materializations docs page's looser phrasing — "a `dbt run` ... is only needed if there is the potential for a change in configuration or sql" — does not survive contact with the branch conditions.)
- Definition change = drop/replace + repopulate, i.e. dbt also has no in-place matview body edit — confirming that any generator this repo writes must emit DROP + CREATE, never a REPLACE.

### 1.9 How each system derives the DOWN body

| System | DOWN body source |
|---|---|
| scenic | Previous numbered file kept on disk (`revert_to_version` re-reads `_v<N-1>.sql`) |
| sqitch rework | Tagged copy of the previous script kept on disk (`<change>@<tag>.sql`) |
| graphile-migrate | None — roll-forward only, by explicit philosophy |
| django-pgviews-redux | None — previous body only in git history |
| sqldef / Atlas / migra | None — declarative; "down" is applying the older desired state |
| dbt | None — no migration ledger at all |
| **This repo today** | Hand-copied previous body pasted into `migrate:down` (see 20260723074556) |

Two viable designs for a generator here: (a) scenic-style — keep every version file, down references `_v<N-1>.sql`; (b) single canonical file per matview, generator embeds the *previous* file content (from git `HEAD` at generation time) verbatim into the `migrate:down` block. (b) keeps dbmate's self-contained-migration property (a migration never reads sibling files at apply time — dbmate has no mechanism for that anyway, see §4) while the canonical file stays singular.

---

## 2. Shared SQL rules as functions inside matview bodies

Candidate extractions in this repo: the `COALESCE(..., '(unknown)')` bucketing expression and the itworx-preferring `CASE`/`ORDER BY (user_email LIKE '%@itworx.com') DESC` tie-break, both now duplicated across fact matviews (20260723074556 repeats each 4–6 times).

### 2.1 When a scalar `LANGUAGE SQL` function is inlined

Source: PostgreSQL wiki, "Inlining of SQL functions" — <https://wiki.postgresql.org/wiki/Inlining_of_SQL_functions>. A scalar function call is replaced by its body in the calling query only if **all** hold:

- the function is `LANGUAGE SQL`; not `SECURITY DEFINER`; not `RETURNS SETOF`/`RETURNS TABLE`; not `RETURNS RECORD`; has no `SET` clauses;
- the body is "a single, simple `SELECT expression`" — no aggregates, window functions, subqueries, CTEs, or `FROM` clause; returns exactly one column whose type matches the declared return type;
- volatility coherence: an `IMMUTABLE` function's body "must not invoke any non-immutable function or operator"; a `STABLE` one must not invoke anything volatile;
- if `STRICT`: every parameter is referenced at least once and everything used in the body is itself `STRICT`;
- a volatile or "expensive" actual argument must not be referenced in the body more than once.

Both candidate expressions here (a `COALESCE` over text, and a `CASE` over two text arguments using `LIKE`) are single-expression, subquery-free, immutable-operator-only scalars — inline-eligible if declared `LANGUAGE SQL IMMUTABLE` with the expression as the whole body. Once inlined, the planner sees the raw expression; matview `REFRESH` cost is identical to today's hand-inlined SQL.

### 2.2 PL/pgSQL is never inlined — confirmed

Inlining's first condition is "the function is `LANGUAGE SQL`" (wiki page above); the table-function inlining conditions likewise require `LANGUAGE SQL`. A `LANGUAGE plpgsql` function is executed through the PL interpreter on every call and is opaque to the planner. (Confirmation is by the exhaustive condition list rather than a sentence saying "plpgsql is not inlined" — the wiki enumerates SQL-language functions only.)

### 2.3 Cost of NOT being inlined during `REFRESH`

Two verified consequences:

- **Parallelism.** `REFRESH MATERIALIZED VIEW` is one of the four utility commands that "can use a parallel plan for the underlying SELECT part of the query" (`CREATE TABLE ... AS`, `SELECT INTO`, `CREATE MATERIALIZED VIEW`, `REFRESH MATERIALIZED VIEW`) — but a parallel plan is refused if "the query uses any function marked `PARALLEL UNSAFE`", and "user-defined functions are marked `PARALLEL UNSAFE` by default." Source: <https://www.postgresql.org/docs/16/when-can-parallel-query-be-used.html>. An inlined function disappears before planning, so its label is moot; a non-inlined one with the default label silently serializes the whole refresh. Rule: declare shared functions `IMMUTABLE PARALLEL SAFE` regardless, so a future inlining-breaking edit doesn't flip refreshes to serial.
- **Per-row executor call.** A non-inlined function is evaluated through the function manager for every row processed — the wiki page's stated motivation for inlining is avoiding function-call overhead. Magnitude at this repo's volumes is untested (**UNVERIFIED** as a measured number; the mechanism itself is what the wiki documents).

### 2.4 New-style bodies (`BEGIN ATOMIC` / `RETURN expr`, PG14+)

Source: <https://www.postgresql.org/docs/16/sql-createfunction.html> (`sql_body`), <https://www.postgresql.org/docs/16/ddl-depend.html>, and commit [e717a9a18](https://github.com/postgres/postgres/commit/e717a9a18b2e34c9c40e5259ad4d31cd7e420750).

- "This form is parsed at function definition time, the string constant form is parsed at execution time"; "The function body is parsed at function definition time and stored as expression nodes in a new pg_proc column prosqlbody" (commit message).
- Dependency bonus: "This form tracks dependencies between the function and objects used in the function body, so `DROP ... CASCADE` will work correctly, whereas the form using string literals may leave dangling functions." ddl-depend spells out the contrast: for string-literal bodies PostgreSQL tracks "not dependencies that could only be known by examining the function body," while for SQL-standard-style bodies "all dependencies recognized by the parser are stored... known and enforced by `DROP`."
- **Still inline-eligible.** PG16 source `src/backend/optimizer/util/clauses.c` handles it explicitly in both `inline_function` (line 4627) and `inline_set_returning_function` (line 5181): `/* If we have prosqlbody, pay attention to that not prosrc */` — the inliner reads `prosqlbody` when present. Source: <https://github.com/postgres/postgres/blob/REL_16_STABLE/src/backend/optimizer/util/clauses.c>.
- Consequence for migration authoring: a `BEGIN ATOMIC` function's *own* dependencies (e.g. on a lookup table) are enforced — dropping that table requires CASCADE or dropping the function first. This cuts both ways: safer, but it constrains migration ordering.

### 2.5 Can you `CREATE OR REPLACE` a function a matview depends on?

Yes — and that is the documented mechanism. The matview *does* depend on functions its query calls (dependencies are recorded through the view's rewrite rule; the body style of the function is irrelevant to the *caller's* dependency), so `DROP FUNCTION` on it fails without CASCADE — the CREATE FUNCTION page warns that dropping and recreating means "you will have to drop existing rules, views, triggers, etc. that refer to the old function." But: "Use `CREATE OR REPLACE FUNCTION` to change a function definition without breaking objects that refer to the function," with the constraints that ownership/permissions are preserved and "it will not let you change the return type of an existing function... It is not possible to change the name or argument types of a function this way." Source: <https://www.postgresql.org/docs/16/sql-createfunction.html>.

Matviews do not store a query *plan*; they store the view query (visible as `pg_matviews.definition`, <https://www.postgresql.org/docs/16/view-pg-matviews.html>), which references the function by identity — so a `CREATE OR REPLACE FUNCTION` with the same signature takes effect at the next `REFRESH` with **no matview drop/recreate needed**. That is the practical payoff for this repo: a rule change like "also treat `@itworx.co` as internal" becomes a 5-line function-replace migration instead of six DROP+CREATE matview blocks — the hourly `marts.refresh_all()` picks it up. (Caveat: signature or return-type changes still force the full drop-function-and-matviews cascade.)

---

## 3. Deriving the refresh list instead of a hand-edited `TEXT[]`

### 3.1 Catalog loop over `pg_matviews`

`pg_matviews` exposes `schemaname`, `matviewname`, `definition`, `ispopulated` for every matview (<https://www.postgresql.org/docs/16/view-pg-matviews.html>). Replacing the hard-coded array in `marts.refresh_all()` with

```sql
SELECT matviewname FROM pg_matviews WHERE schemaname = 'marts' ORDER BY matviewname
```

eliminates the drift failure mode (new mart forgotten in the array; today nothing fails — the mart just silently never refreshes). In this repo all 14 matviews read only raw tables and plain staging views — none reads another matview — so refresh order is currently irrelevant and an alphabetical loop is correct.

### 3.2 Dependency-ordered refresh (only if matview-on-matview appears)

The canonical recipe is the PostgreSQL wiki page "Refresh All Materialized Views" (<https://wiki.postgresql.org/wiki/Refresh_All_Materialized_Views>): a recursive CTE (`mat_view_dependencies`) walks `pg_depend` joined through `pg_rewrite` (`pg_depend d ON c.oid = d.refobjid`, `pg_rewrite r ON d.objid = r.oid`, `pg_class c2 ON r.ev_class = c2.oid`) — view dependencies hang off the view's `_RETURN` rewrite rule, not the relation directly — filters `relkind = 'm'`, excludes self-references, and takes MAX(depth) per matview as `refresh_order`. A companion view emits ordered `REFRESH MATERIALIZED VIEW` statements. That CTE drops into `refresh_all()` as-is if a mart ever stacks on another mart.

Standalone orchestrators exist but add nothing for a repo that already owns `refresh_all()`: [aanari/pg-materialize](https://github.com/aanari/pg-materialize) (Python; parses source SQL files into a DAG and emits creation/refresh order — build-time, not catalog-driven) and community gists doing the recursive-`pg_depend` walk at runtime (e.g. <https://gist.github.com/bitdivine/4b63fb088fd8fd58d61ffb8246d07369>). Neither is packaged/maintained at a level that beats 20 lines of SQL in the existing function.

**COMMENT ON / naming-convention ordering:** no established convention was found in primary sources (no tool or wiki page encodes refresh order in `COMMENT ON` or in name prefixes). Verdict: don't invent one; catalog order (with the pg_depend CTE as the future escalation) is the documented pattern.

One behavioral note: the `TEXT[]` today is also an *inclusion* list. A catalog loop refreshes every matview in `marts` — including any future mart intentionally excluded from hourly refresh. If that ever matters, exclusion belongs in data (a registry row or a `NOT ... = ANY(excluded)` guard), not back in a hand-edited array.

### 3.3 Ordering within this repo's gate

The same `pg_matviews` query doubles as a drift gate: a CI check can assert that every matview under `db/views/` (if the definition-file layout lands) exists in `pg_matviews` and vice versa — the equivalent of `spec_sync --check`'s convergence proof, applied to marts.

---

## 4. dbmate-native support — none, confirmed

Sources: <https://github.com/amacneil/dbmate> (README, v2.x); `gh search issues --repo amacneil/dbmate "repeatable"` (2026-07-24).

- The README documents exactly: plain-SQL migrations with `migrate:up` / `migrate:down` blocks (multiple blocks per file allowed), a `transaction:false` directive, automatic `./db/schema.sql` dump plus `dbmate dump` / `dbmate load`. **No** view definition files, **no** repeatable migrations, **no** hooks, **no** schema diffing, **no** generated migrations, and no mention of views or matviews anywhere.
- Issue search for "repeatable" returns nothing on point (only #118, env vars in scripts, closed); there is no open feature request tracking Flyway-style repeatables. (**UNVERIFIED** that no such request exists in Discussions — GitHub search covered issues only.)
- The Flyway prior art, for reference: repeatable migrations (`R__*.sql`) "have a description and a checksum, but no version... they are (re-)applied every time their checksum changes," and "within a single migration run, repeatable migrations are always applied last, after all pending versioned migrations" — with no undo support ([flyway migrations concept doc](https://github.com/flyway/flywaydb.org/blob/gh-pages/documentation/concepts/migrations.md), [flyway#2078](https://github.com/flyway/flyway/issues/2078)). That is the exact "canonical current body, re-applied on change" semantics this research is about — and dbmate simply does not have it.

Verdict as expected: with dbmate staying (settled in `docs/research/dev-tooling-stack.md`), the pattern has to be a **generator that emits ordinary dbmate migrations** — the precedent already in-tree is `tools/spec_sync.py --name <slug>` (reads the Python column spec, diffs against a from-zero DB, writes an additive migration with a down section, applies it, regenerates `schema.sql`). The matview analogue reads definition files instead of a column spec.

---

## Recommendation — ranked for cc-otel

Constraints honored: dbmate stays; the schema-drift gate (`scripts/dev-migrate.sh --check`) stays and keeps `db/schema.sql` as ground truth; matviews need DROP+CREATE (no `OR REPLACE` exists); down migrations must restore the previous body; `spec_sync` is the in-house generator precedent.

1. **Definition files + a `spec_sync`-style generator (scenic pattern, ported).** One canonical SQL file per mart (e.g. `db/views/marts/fact_session.sql` carrying body + unique index + grant, or body-only with index/grant in a small header spec). `tools/matview_sync --name <slug>` emits a dbmate migration whose `migrate:up` is DROP + CREATE + index + GRANT from the current file and whose `migrate:down` is the same rendered from the *previous* content. Down-body variant to decide at design time: (a) scenic-style numbered version files kept on disk (`fact_session_v03.sql`; migration provenance is explicit, directory grows forever) vs (b) single file per mart with the previous body embedded verbatim into `migrate:down` at generation time (fits dbmate's self-contained migrations — dbmate cannot read sibling files at apply time — and the canonical file stays singular; git history holds the lineage). (b) is the better dbmate fit. Add a `--check` mode asserting each file's body matches `pg_matviews.definition` on a from-zero DB — the same convergence gate `spec_sync --check` already models. This is a genuine fork in repo workflow → HITL before building.
2. **Catalog-drive `refresh_all()` now, independently of #1.** Replace the `TEXT[]` with a `FOR mv IN SELECT matviewname FROM pg_matviews WHERE schemaname = 'marts' ORDER BY matviewname` loop (one small migration). Zero new machinery, kills the forgotten-matview drift risk today. Wire in the wiki's `pg_depend` recursive CTE only if a mart ever reads another mart.
3. **Extract the two shared rules as `LANGUAGE SQL` functions — narrowly.** `marts.email_bucket(text)` (the COALESCE-to-'(unknown)') and `marts.prefer_itworx(text, text)` (the CASE tie-break), declared `IMMUTABLE PARALLEL SAFE`, single-expression bodies (inline-eligible per §2.1), written `BEGIN ATOMIC`/`RETURN` style for dependency tracking (§2.4). Payoff: the next rule change is a `CREATE OR REPLACE FUNCTION` migration + next hourly refresh — no matview DROP+CREATE at all (§2.5). Cost: the matview→function dependency means those functions can never be signature-changed or dropped without cascading through the marts.
4. **Rejected:** switching the migration runner or paradigm — sqldef/Atlas/sqitch (replace dbmate; Atlas additionally paywalls matviews), dbt (abandons migrations, and its own macro only REFRESHes on a SQL-text change without `--full-refresh`), migra (deprecated), sync-on-migrate outside the ledger (django-pgviews-redux) which the drift gate exists to prevent.
