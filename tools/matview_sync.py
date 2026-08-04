"""Canonical definition files + migration generator (#263, #426).

Every view, materialized view, and function in the ``marts`` + ``staging``
schemas has its body exactly once, as a canonical SQL file on disk; their
migrations are *generated* from those files, never hand-pasted. This ends the
era where an object's "current" body lived in whichever migration last touched
it (``fact_session_daily`` once existed in 7 physical copies;
``marts.refresh_all()`` reached 20). Decisions locked in #254 (marts matviews)
and #426 (full class: plain views + functions).

Layout — ``db/<tier>/<schema>/<name>.sql``:

    db/views/marts/       matviews + marts plain views (kind read from the catalog)
    db/views/staging/     staging views
    db/functions/marts/   marts functions

    uv run python -m tools.matview_sync --check [--database-url URL]
        Gate: on a from-zero DB, prove every object's canonical file converges
        with its catalog deparse (``pg_matviews.definition`` /
        ``pg_views.definition`` / ``pg_get_functiondef()``), bidirectionally —
        every live object has a file, every file a live object, and the
        rendered body matches. Exit 1 on any divergence. Connects to an
        already-migrated DB (``--database-url`` / ``$DATABASE_URL``) or, with
        neither, spins its own throwaway ``postgres:16`` and applies migrations.

    uv run python -m tools.matview_sync --name <slug>
        Author: render a dbmate migration from the edited canonical file (found
        across the three dirs). A matview's ``migrate:up`` is DROP + CREATE +
        index + GRANT; a plain view's or function's is the file verbatim —
        ``CREATE OR REPLACE``, no DROP, because ``stg_seat_interval`` has
        matview dependents and a CASCADE would drop marts. Where OR REPLACE is
        structurally impossible (column rename/drop/reorder) the throwaway-DB
        apply fails loudly; hand-author that one cascade migration from the
        canonical files. ``migrate:down`` embeds the *previous* body verbatim
        from git HEAD (dbmate migrations are self-contained — they cannot read
        sibling files at apply time). Applies it on a throwaway DB, normalizes
        the file to the deparser form, and verifies convergence. Regenerating
        schema.sql is left to its owner, ``scripts/dev-migrate.sh`` (unlike
        ``spec_sync``, which shells out to it — matview_sync stays shell-free
        so it runs on Windows and CI alike).

    uv run python -m tools.matview_sync --bootstrap [--database-url URL]
        One-time: extract every live object body to its canonical file. Idempotent.

The canonical body is stored as the deparser's own output, so ``--check`` is a
byte-exact render-and-compare (like ``dev-migrate.sh --check`` for schema.sql)
— no whitespace normalization, no parsing, deterministic on the pinned
``postgres:16``.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import psycopg

from tools import _ephemeral_pg

_REPO_ROOT = Path(__file__).resolve().parents[1]
_MIGRATIONS_DIR = _REPO_ROOT / "db" / "migrations"
_READ_ROLE = "cc_otel_read"
_CONTAINER = "cc-otel-matview-sync"
_SCHEMAS = ("marts", "staging")

_HEADER = (
    "-- Canonical definition for {schema}.{name}.\n"
    "-- Source of truth for the {noun} body; edit here, then regenerate the migration:\n"
    "--   uv run python -m tools.matview_sync --name {name}\n"
    "-- Verified against {catalog} by --check (CI + local gate).\n"
)

# Per-kind facts: the header noun, the catalog --check reads, and the dir tier
# the canonical file lives under (db/<tier>/<schema>/<name>.sql).
_KINDS: dict[str, tuple[str, str, str]] = {
    "matview": ("mart", "pg_matviews.definition", "views"),
    "view": ("view", "pg_views.definition", "views"),
    "function": ("function", "pg_get_functiondef()", "functions"),
}

# The CREATE line every canonical file opens its DDL with — how --name learns
# an object's kind and schema without a live catalog (a brand-new object has
# no catalog row yet).
_CREATE_RE = re.compile(
    r"^CREATE (MATERIALIZED VIEW|OR REPLACE VIEW|OR REPLACE FUNCTION)"
    r" (marts|staging)\.([a-z_][a-z0-9_]*)",
    re.MULTILINE,
)
_KIND_BY_CREATE = {
    "MATERIALIZED VIEW": "matview",
    "OR REPLACE VIEW": "view",
    "OR REPLACE FUNCTION": "function",
}


# --- model --------------------------------------------------------------------


@dataclass(frozen=True)
class DbObject:
    """A live object under the canonical seam: matview, plain view, or function.

    ``definition`` is the deparser's verbatim output — ``pg_matviews.definition``
    / ``pg_views.definition`` (leading space, trailing ``;``) for the view kinds,
    ``pg_get_functiondef()`` (a complete CREATE OR REPLACE, no ``;``) for
    functions. ``index_def`` is the matview's unique index (no ``;``); ``None``
    for the other kinds."""

    kind: str  # 'matview' | 'view' | 'function'
    schema: str  # 'marts' | 'staging'
    name: str
    definition: str
    index_def: str | None = None


# --- render (pure) ------------------------------------------------------------


def render_canonical(obj: DbObject) -> str:
    """The canonical file text for ``obj``, per kind.

    Pure and deterministic — the single renderer used by both ``--bootstrap``
    (write to disk) and ``--check`` (render from live, compare to disk). A marts
    view or matview carries the reader grant; staging objects and functions
    have none to carry (#426)."""
    noun, catalog, _ = _KINDS[obj.kind]
    header = _HEADER.format(schema=obj.schema, name=obj.name, noun=noun, catalog=catalog)
    grant = f"\nGRANT SELECT ON {obj.schema}.{obj.name} TO {_READ_ROLE};\n"
    if obj.kind == "matview":
        return (
            header
            + f"CREATE MATERIALIZED VIEW {obj.schema}.{obj.name} AS\n"
            + f"{obj.definition}\n"
            + "\n"
            + f"{obj.index_def};\n"
            + grant
        )
    if obj.kind == "view":
        body = header + f"CREATE OR REPLACE VIEW {obj.schema}.{obj.name} AS\n{obj.definition}\n"
        return body + grant if obj.schema == "marts" else body
    return header + f"{obj.definition.rstrip()};\n"


def render_migration(slug: str, current: str, previous: str | None) -> str:
    """Render a dbmate migration recreating ``<schema>.<slug>`` from its canonical file.

    ``current`` is the on-disk file (desired state); ``previous`` is the same file
    at git HEAD (``None`` for a brand-new object). Kind and schema are read from
    the file's own CREATE line. A matview redefinition is DROP + CREATE both
    ways; a plain view or function is CREATE OR REPLACE both ways — no DROP, so
    dependents survive (#426). The up/down bodies embed each file body (trailing
    whitespace trimmed so the section separators stay clean) — git history is
    the lineage.

    The embedded bodies are verbatim catalog deparse (byte-exact for --check),
    which is not sqlfluff-clean — the same reason the canonical files under
    db/views/ + db/functions/ are excluded from the sqlfluff hook. A generated
    migration embeds those same dumps, so it opts the whole file out of linting
    with a file-level ``-- noqa: disable=all`` (filename-independent, unlike a
    pre-commit exclude pattern)."""
    match = _CREATE_RE.search(current)
    if match is None:
        raise ValueError(f"{slug}: no recognizable CREATE line in the canonical file")
    kind = _KIND_BY_CREATE[match.group(1)]
    schema, name = match.group(2), match.group(3)
    if name != slug:
        raise ValueError(f"{slug}: canonical file creates {schema}.{name}, not {slug}")
    if kind == "matview":
        if previous is not None:
            up_body = f"DROP MATERIALIZED VIEW {schema}.{slug};\n\n{current.rstrip()}"
            down_body = f"DROP MATERIALIZED VIEW {schema}.{slug};\n\n{previous.rstrip()}"
        else:
            up_body = current.rstrip()
            down_body = f"DROP MATERIALIZED VIEW IF EXISTS {schema}.{slug};"
    else:
        up_body = current.rstrip()
        if previous is not None:
            down_body = previous.rstrip()
        else:
            drop_word = "VIEW" if kind == "view" else "FUNCTION"
            down_body = f"DROP {drop_word} IF EXISTS {schema}.{slug};"
    return (
        f"-- migrate:up\n-- matview_sync: {slug}\n-- noqa: disable=all\n\n"
        f"{up_body}\n\n-- migrate:down\n\n{down_body}\n"
    )


# --- divergence (pure) --------------------------------------------------------


@dataclass
class Divergence:
    missing_files: list[str] = field(default_factory=list)  # live object, no on-disk file
    orphan_files: list[str] = field(default_factory=list)  # on-disk file, no live object
    mismatched: list[str] = field(default_factory=list)  # body edited without a migration

    def empty(self) -> bool:
        return not (self.missing_files or self.orphan_files or self.mismatched)

    def report(self) -> str:
        lines: list[str] = []
        for name in self.missing_files:
            lines.append(f"  live object with no canonical file (run --bootstrap): {name}")
        for name in self.orphan_files:
            lines.append(f"  canonical file with no live object (delete the file?): {name}")
        for name in self.mismatched:
            lines.append(f"  file edited without a migration (run --name {name}): {name}")
        return "\n".join(lines)


def compute_divergence(rendered: dict[str, str], disk: dict[str, str]) -> Divergence:
    """Diff live objects (rendered to canonical text) against on-disk files, by name."""
    live_names = set(rendered)
    disk_names = set(disk)
    return Divergence(
        missing_files=sorted(live_names - disk_names),
        orphan_files=sorted(disk_names - live_names),
        mismatched=sorted(n for n in live_names & disk_names if rendered[n] != disk[n]),
    )


# --- db reader ----------------------------------------------------------------


def read_live_objects(conn: psycopg.Connection) -> list[DbObject]:
    """Every matview, plain view, and function in ``marts`` + ``staging``.

    Matviews additionally carry their unique index (exactly one, enforced);
    ``prokind = 'f'`` keeps aggregates/procedures out — none exist in these
    schemas and the canonical seam models plain functions only."""
    objects: list[DbObject] = []
    with conn.cursor() as cur:
        cur.execute(
            "SELECT schemaname, matviewname, definition FROM pg_matviews "
            "WHERE schemaname = ANY(%s) ORDER BY schemaname, matviewname",
            (list(_SCHEMAS),),
        )
        matviews = cur.fetchall()
    for schema, name, definition in matviews:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT indexdef FROM pg_indexes "
                "WHERE schemaname = %s AND tablename = %s "
                "AND indexdef LIKE 'CREATE UNIQUE INDEX%%'",
                (schema, name),
            )
            idx = cur.fetchall()
        if len(idx) != 1:
            raise RuntimeError(
                f"{schema}.{name}: expected exactly one unique index, found {len(idx)}"
            )
        objects.append(
            DbObject(
                kind="matview",
                schema=schema,
                name=name,
                definition=definition.rstrip(),
                index_def=idx[0][0],
            )
        )
    with conn.cursor() as cur:
        cur.execute(
            "SELECT schemaname, viewname, definition FROM pg_views "
            "WHERE schemaname = ANY(%s) ORDER BY schemaname, viewname",
            (list(_SCHEMAS),),
        )
        views = cur.fetchall()
    for schema, name, definition in views:
        objects.append(
            DbObject(kind="view", schema=schema, name=name, definition=definition.rstrip())
        )
    with conn.cursor() as cur:
        cur.execute(
            "SELECT n.nspname, p.proname, pg_get_functiondef(p.oid) "
            "FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
            "WHERE n.nspname = ANY(%s) AND p.prokind = 'f' "
            "ORDER BY n.nspname, p.proname",
            (list(_SCHEMAS),),
        )
        functions = cur.fetchall()
    for schema, name, definition in functions:
        objects.append(DbObject(kind="function", schema=schema, name=name, definition=definition))
    return objects


def _object_dir(obj: DbObject) -> Path:
    """The canonical dir for ``obj``: ``db/<tier>/<schema>/``."""
    _, _, tier = _KINDS[obj.kind]
    return _REPO_ROOT / "db" / tier / obj.schema


def _canonical_paths() -> list[Path]:
    """Every canonical file on disk, across the views and functions tiers."""
    paths: list[Path] = []
    for tier in ("views", "functions"):
        root = _REPO_ROOT / "db" / tier
        if root.exists():
            paths.extend(root.glob("*/*.sql"))
    return sorted(paths)


def disk_files() -> dict[str, str]:
    """``{object_name: file_text}`` for every canonical file on disk.

    Object names are the divergence key, so a stem duplicated across dirs is a
    hard error rather than a silent last-write-wins."""
    files: dict[str, str] = {}
    for p in _canonical_paths():
        if p.stem in files:
            raise RuntimeError(f"duplicate canonical file name across dirs: {p.stem}")
        files[p.stem] = p.read_text(encoding="utf-8")
    return files


def _rendered_live(conn: psycopg.Connection) -> dict[str, str]:
    rendered: dict[str, str] = {}
    for obj in read_live_objects(conn):
        if obj.name in rendered:
            raise RuntimeError(f"duplicate object name across schemas/kinds: {obj.name}")
        rendered[obj.name] = render_canonical(obj)
    return rendered


def divergence(conn: psycopg.Connection) -> Divergence:
    return compute_divergence(_rendered_live(conn), disk_files())


# --- CLI ----------------------------------------------------------------------


def _find_canonical(slug: str) -> Path | None:
    """The canonical file for ``slug``, searched across the three dirs."""
    for p in _canonical_paths():
        if p.stem == slug:
            return p
    return None


def _git_head_file(path: Path) -> str | None:
    """The canonical file at git HEAD, or ``None`` if it isn't tracked yet."""
    rel = path.relative_to(_REPO_ROOT).as_posix()
    result = subprocess.run(
        ["git", "show", f"HEAD:{rel}"],
        cwd=_REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout if result.returncode == 0 else None


def _run_check(database_url: str | None) -> int:
    with _ephemeral_pg.connection(database_url, _CONTAINER, _MIGRATIONS_DIR) as conn:
        div = divergence(conn)
    if not div.empty():
        print(
            "matview_sync: canonical files <-> live objects divergence:\n" + div.report(),
            file=sys.stderr,
        )
        return 1
    print("matview_sync: every object body converges with its canonical file.")
    return 0


def _run_bootstrap(database_url: str | None) -> int:
    with _ephemeral_pg.connection(database_url, _CONTAINER, _MIGRATIONS_DIR) as conn:
        objects = read_live_objects(conn)
    for obj in objects:
        dest_dir = _object_dir(obj)
        dest_dir.mkdir(parents=True, exist_ok=True)
        (dest_dir / f"{obj.name}.sql").write_text(
            render_canonical(obj), encoding="utf-8", newline="\n"
        )
    print(f"matview_sync: wrote {len(objects)} canonical files under db/views + db/functions")
    return 0


def _run_author(slug: str) -> int:
    # The slug is interpolated into file paths and unquoted SQL identifiers; keep
    # it to the shape every real object already has so a typo can't escape the
    # dir or malform the migration.
    if not re.fullmatch(r"[a-z][a-z0-9_]*", slug):
        print(
            f"matview_sync: invalid slug {slug!r} — expected lowercase [a-z][a-z0-9_]*",
            file=sys.stderr,
        )
        return 1
    src = _find_canonical(slug)
    if src is None:
        print(
            f"matview_sync: no canonical file named {slug}.sql under db/views/ or db/functions/",
            file=sys.stderr,
        )
        return 1
    current = src.read_text(encoding="utf-8")
    previous = _git_head_file(src)
    if previous is not None and previous == current:
        print(f"matview_sync: {slug} unchanged since HEAD — nothing to do.")
        return 0
    stamp = datetime.now(UTC).strftime("%Y%m%d%H%M%S")
    dest = _MIGRATIONS_DIR / f"{stamp}_{slug}.sql"
    try:
        migration = render_migration(slug, current, previous)
    except ValueError as exc:
        print(f"matview_sync: {exc}", file=sys.stderr)
        return 1
    dest.write_text(migration, encoding="utf-8", newline="\n")
    print(f"matview_sync: wrote {dest.relative_to(_REPO_ROOT)}")
    # Apply every migration (incl. the new one) on a throwaway DB, then normalize
    # the canonical file — and the migration's up-body — to the deparser's own
    # form, so a hand-edit in any style still converges under --check. Pure
    # Docker + psycopg (no shell-out) so this runs identically on Windows and
    # CI. schema.sql regeneration stays with its owner, scripts/dev-migrate.sh.
    with _ephemeral_pg.ephemeral_db(_CONTAINER, _MIGRATIONS_DIR) as conn:
        live = {o.name: o for o in read_live_objects(conn)}
        if slug not in live:
            print(f"matview_sync: migration did not create {slug}.", file=sys.stderr)
            return 1
        normalized = render_canonical(live[slug])
        if normalized != current:
            src.write_text(normalized, encoding="utf-8", newline="\n")
            dest.write_text(
                render_migration(slug, normalized, previous), encoding="utf-8", newline="\n"
            )
            print(f"matview_sync: normalized {src.relative_to(_REPO_ROOT)} to the deparser form")
        div = divergence(conn)
    if not div.empty():
        print(
            "matview_sync: generated migration did not converge:\n" + div.report(),
            file=sys.stderr,
        )
        return 1
    print(
        "matview_sync: migration written; canonical file converges. "
        "Run scripts/dev-migrate.sh to regenerate db/schema.sql."
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="matview_sync", description=__doc__)
    parser.add_argument("--check", action="store_true", help="gate mode (default)")
    parser.add_argument("--name", help="author mode: object slug to generate a migration for")
    parser.add_argument("--bootstrap", action="store_true", help="one-time: extract object bodies")
    parser.add_argument("--database-url", help="already-migrated DB for --check / --bootstrap")
    args = parser.parse_args(argv)

    if args.name:
        return _run_author(args.name)
    url = args.database_url or os.environ.get("DATABASE_URL")
    if args.bootstrap:
        return _run_bootstrap(url)
    return _run_check(url)


if __name__ == "__main__":
    raise SystemExit(main())
