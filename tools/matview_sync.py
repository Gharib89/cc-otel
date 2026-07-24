"""Canonical mart definition files + migration generator (#263).

Every mart's body lives exactly once, as a canonical SQL file on disk under
``db/views/marts/``; mart migrations are *generated* from those files, never
hand-pasted. This ends the era where a mart's "current" body lived in whichever
migration last touched it (``fact_session_daily`` once existed in 7 physical
copies). Decisions locked in #254.

    uv run python -m tools.matview_sync --check [--database-url URL]
        Gate: on a from-zero DB, prove every mart's canonical file converges
        with ``pg_matviews.definition`` (+ its unique index and reader grant),
        bidirectionally — every mart has a file, every file has a mart, and the
        rendered body matches. Exit 1 on any divergence. Connects to an
        already-migrated DB (``--database-url`` / ``$DATABASE_URL``) or, with
        neither, spins its own throwaway ``postgres:16`` and applies migrations.

    uv run python -m tools.matview_sync --name <slug>
        Author: render a dbmate migration from an edited ``db/views/marts/<slug>.sql``
        — ``migrate:up`` is DROP + CREATE + index + GRANT from the current file;
        ``migrate:down`` embeds the *previous* body verbatim from git HEAD (dbmate
        migrations are self-contained — they cannot read sibling files at apply
        time). Applies it on a throwaway DB, normalizes the file to the deparser
        form, and verifies convergence. Regenerating schema.sql is left to its
        owner, ``scripts/dev-migrate.sh`` (unlike ``spec_sync``, which shells out
        to it — matview_sync stays shell-free so it runs on Windows and CI alike).

    uv run python -m tools.matview_sync --bootstrap [--database-url URL]
        One-time: extract every live mart body to its canonical file. Idempotent.

The canonical body is stored as the deparser's own ``pg_matviews.definition``
output, so ``--check`` is a byte-exact render-and-compare (like
``dev-migrate.sh --check`` for schema.sql) — no whitespace normalization, no
parsing, deterministic on the pinned ``postgres:16``.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import psycopg

_REPO_ROOT = Path(__file__).resolve().parents[1]
_MIGRATIONS_DIR = _REPO_ROOT / "db" / "migrations"
_VIEWS_DIR = _REPO_ROOT / "db" / "views" / "marts"
_READ_ROLE = "cc_otel_read"

_HEADER = (
    "-- Canonical definition for marts.{name}.\n"
    "-- Source of truth for the mart body; edit here, then regenerate the migration:\n"
    "--   uv run python -m tools.matview_sync --name {name}\n"
    "-- Verified against pg_matviews.definition by --check (CI + local gate).\n"
)


# --- model --------------------------------------------------------------------


@dataclass(frozen=True)
class Mart:
    """A live materialized view: its deparsed body and unique-index DDL."""

    name: str
    definition: str  # pg_matviews.definition verbatim (leading space, trailing ;)
    index_def: str  # pg_indexes.indexdef for the mart's unique index (no ;)


# --- render (pure) ------------------------------------------------------------


def render_canonical(mart: Mart) -> str:
    """The canonical file text for ``mart``: header + CREATE + unique index + grant.

    Pure and deterministic — the single renderer used by both ``--bootstrap``
    (write to disk) and ``--check`` (render from live, compare to disk)."""
    return (
        _HEADER.format(name=mart.name)
        + f"CREATE MATERIALIZED VIEW marts.{mart.name} AS\n"
        + f"{mart.definition}\n"
        + "\n"
        + f"{mart.index_def};\n"
        + "\n"
        + f"GRANT SELECT ON marts.{mart.name} TO {_READ_ROLE};\n"
    )


def render_migration(slug: str, current: str, previous: str | None) -> str:
    """Render a dbmate migration recreating ``marts.<slug>`` from its canonical file.

    ``current`` is the on-disk file (desired state); ``previous`` is the same file
    at git HEAD (``None`` for a brand-new mart). The up/down bodies embed the file
    contents verbatim — git history is the lineage."""
    if previous is not None:
        up_body = f"DROP MATERIALIZED VIEW marts.{slug};\n\n{current.rstrip()}"
        down_body = f"DROP MATERIALIZED VIEW marts.{slug};\n\n{previous.rstrip()}"
    else:
        up_body = current.rstrip()
        down_body = f"DROP MATERIALIZED VIEW IF EXISTS marts.{slug};"
    return (
        f"-- migrate:up\n-- matview_sync: {slug}\n\n{up_body}\n\n-- migrate:down\n\n{down_body}\n"
    )


# --- divergence (pure) --------------------------------------------------------


@dataclass
class Divergence:
    missing_files: list[str] = field(default_factory=list)  # live mart, no on-disk file
    orphan_files: list[str] = field(default_factory=list)  # on-disk file, no live mart
    mismatched: list[str] = field(default_factory=list)  # body edited without a migration

    def empty(self) -> bool:
        return not (self.missing_files or self.orphan_files or self.mismatched)

    def report(self) -> str:
        lines: list[str] = []
        for name in self.missing_files:
            lines.append(f"  live mart with no canonical file (run --bootstrap): {name}")
        for name in self.orphan_files:
            lines.append(f"  canonical file with no live mart (delete the file?): {name}")
        for name in self.mismatched:
            lines.append(f"  file edited without a migration (run --name {name}): {name}")
        return "\n".join(lines)


def compute_divergence(rendered: dict[str, str], disk: dict[str, str]) -> Divergence:
    """Diff live marts (rendered to canonical text) against on-disk files, by name."""
    live_names = set(rendered)
    disk_names = set(disk)
    return Divergence(
        missing_files=sorted(live_names - disk_names),
        orphan_files=sorted(disk_names - live_names),
        mismatched=sorted(n for n in live_names & disk_names if rendered[n] != disk[n]),
    )


# --- db reader ----------------------------------------------------------------


def read_live_marts(conn: psycopg.Connection) -> list[Mart]:
    """Every matview in the ``marts`` schema, with its body and unique index."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT matviewname, definition FROM pg_matviews "
            "WHERE schemaname = 'marts' ORDER BY matviewname"
        )
        rows = cur.fetchall()
    marts: list[Mart] = []
    for name, definition in rows:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT indexdef FROM pg_indexes "
                "WHERE schemaname = 'marts' AND tablename = %s "
                "AND indexdef LIKE 'CREATE UNIQUE INDEX%%'",
                (name,),
            )
            idx = cur.fetchall()
        if len(idx) != 1:
            raise RuntimeError(f"marts.{name}: expected exactly one unique index, found {len(idx)}")
        marts.append(Mart(name=name, definition=definition.rstrip(), index_def=idx[0][0]))
    return marts


def disk_files() -> dict[str, str]:
    """``{mart_name: file_text}`` for every canonical file on disk."""
    if not _VIEWS_DIR.exists():
        return {}
    return {p.stem: p.read_text(encoding="utf-8") for p in sorted(_VIEWS_DIR.glob("*.sql"))}


def divergence(conn: psycopg.Connection) -> Divergence:
    rendered = {m.name: render_canonical(m) for m in read_live_marts(conn)}
    return compute_divergence(rendered, disk_files())


# --- ephemeral DB (self-provision when no URL is given) -----------------------


def _up_section(sql: str) -> str:
    return sql.split("-- migrate:up", 1)[1].split("-- migrate:down", 1)[0]


def _apply_migrations(conn: psycopg.Connection) -> None:
    conn.autocommit = True
    for path in sorted(_MIGRATIONS_DIR.glob("*.sql")):
        up = _up_section(path.read_text(encoding="utf-8")).strip()
        if up:
            conn.execute(up)  # type: ignore[arg-type]


@contextmanager
def _ephemeral_db() -> Iterator[psycopg.Connection]:
    """Spin a throwaway ``postgres:16``, apply every migration, yield a connection."""
    name = "cc-otel-matview-sync"
    subprocess.run(["docker", "rm", "-f", name], capture_output=True, check=False)
    subprocess.run(
        [
            "docker",
            "run",
            "-d",
            "--name",
            name,
            "-e",
            "POSTGRES_USER=postgres",
            "-e",
            "POSTGRES_PASSWORD=postgres",
            "-e",
            "POSTGRES_DB=cc_otel",
            "-p",
            "127.0.0.1::5432",
            "postgres:16",
        ],
        check=True,
        capture_output=True,
    )
    try:
        port = (
            subprocess.run(
                ["docker", "port", name, "5432"], check=True, capture_output=True, text=True
            )
            .stdout.strip()
            .rsplit(":", 1)[-1]
        )
        url = f"postgres://postgres:postgres@127.0.0.1:{port}/cc_otel?sslmode=disable"
        conn = None
        for _ in range(30):
            try:
                conn = psycopg.connect(url)
                break
            except psycopg.OperationalError:
                time.sleep(1)
        if conn is None:
            raise RuntimeError("ephemeral Postgres did not become ready within 30s")
        with conn:
            _apply_migrations(conn)
            yield conn
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, check=False)


@contextmanager
def _connection(database_url: str | None) -> Iterator[psycopg.Connection]:
    if database_url:
        with psycopg.connect(database_url) as conn:
            yield conn
    else:
        with _ephemeral_db() as conn:
            yield conn


# --- CLI ----------------------------------------------------------------------


def _git_head_file(slug: str) -> str | None:
    """The canonical file at git HEAD, or ``None`` if it isn't tracked yet."""
    rel = f"db/views/marts/{slug}.sql"
    result = subprocess.run(
        ["git", "show", f"HEAD:{rel}"],
        cwd=_REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout if result.returncode == 0 else None


def _run_check(database_url: str | None) -> int:
    with _connection(database_url) as conn:
        div = divergence(conn)
    if not div.empty():
        print(
            "matview_sync: canonical files <-> marts divergence:\n" + div.report(),
            file=sys.stderr,
        )
        return 1
    print("matview_sync: every mart body converges with its canonical file.")
    return 0


def _run_bootstrap(database_url: str | None) -> int:
    _VIEWS_DIR.mkdir(parents=True, exist_ok=True)
    with _connection(database_url) as conn:
        marts = read_live_marts(conn)
    for mart in marts:
        dest = _VIEWS_DIR / f"{mart.name}.sql"
        dest.write_text(render_canonical(mart), encoding="utf-8")
    rel = _VIEWS_DIR.relative_to(_REPO_ROOT)
    print(f"matview_sync: wrote {len(marts)} canonical files to {rel}")
    return 0


def _run_author(slug: str) -> int:
    # The slug is interpolated into file paths and unquoted SQL identifiers; keep
    # it to the shape every real mart already has so a typo can't escape the dir
    # or malform the migration.
    if not re.fullmatch(r"[a-z][a-z0-9_]*", slug):
        print(
            f"matview_sync: invalid slug {slug!r} — expected lowercase [a-z][a-z0-9_]*",
            file=sys.stderr,
        )
        return 1
    src = _VIEWS_DIR / f"{slug}.sql"
    if not src.exists():
        print(f"matview_sync: no canonical file at {src.relative_to(_REPO_ROOT)}", file=sys.stderr)
        return 1
    current = src.read_text(encoding="utf-8")
    previous = _git_head_file(slug)
    if previous is not None and previous == current:
        print(f"matview_sync: {slug} unchanged since HEAD — nothing to do.")
        return 0
    stamp = datetime.now(UTC).strftime("%Y%m%d%H%M%S")
    dest = _MIGRATIONS_DIR / f"{stamp}_{slug}.sql"
    dest.write_text(render_migration(slug, current, previous), encoding="utf-8")
    print(f"matview_sync: wrote {dest.relative_to(_REPO_ROOT)}")
    # Apply every migration (incl. the new one) on a throwaway DB, then normalize
    # the canonical file — and the migration's up-body — to pg_matviews' own
    # deparsed form, so a hand-edit in any style still converges under --check.
    # Pure Docker + psycopg (no shell-out) so this runs identically on Windows and
    # CI. schema.sql regeneration stays with its owner, scripts/dev-migrate.sh.
    with _ephemeral_db() as conn:
        live = {m.name: m for m in read_live_marts(conn)}
        if slug not in live:
            print(f"matview_sync: migration did not create marts.{slug}.", file=sys.stderr)
            return 1
        normalized = render_canonical(live[slug])
        if normalized != current:
            src.write_text(normalized, encoding="utf-8")
            dest.write_text(render_migration(slug, normalized, previous), encoding="utf-8")
            print(f"matview_sync: normalized {src.relative_to(_REPO_ROOT)} to pg_matviews form")
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
    parser.add_argument("--name", help="author mode: mart slug to generate a migration for")
    parser.add_argument("--bootstrap", action="store_true", help="one-time: extract mart bodies")
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
