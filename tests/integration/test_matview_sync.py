"""DB-backed proof for the canonical definition files + generator (#263, #426).

Guarantees the pure unit layer can't give:
- every committed canonical file converges with its live object on a from-zero
  DB (bidirectional — the `--check` gate contract), across all three kinds;
- a generated migration's up->down->up roundtrip reverses and re-converges,
  per kind — including that a plain view's CREATE OR REPLACE leaves its
  dependents standing (#426's reason for never generating a DROP).

A view's down is CREATE OR REPLACE of the previous body, so a column-narrowing
down fails loudly by design (Postgres forbids dropping columns via OR REPLACE)
— the same hand-authored-cascade escape hatch as a structural up. The
roundtrips here exercise the always-legal body-only change.
"""

from __future__ import annotations

import shutil

import psycopg
import pytest

from tools import matview_sync as ms
from tools.matview_sync import (
    DbObject,
    divergence,
    read_live_objects,
    render_canonical,
    render_migration,
)


def _up(sql: str) -> str:
    return sql.split("-- migrate:up", 1)[1].split("-- migrate:down", 1)[0].strip()


def _down(sql: str) -> str:
    return sql.split("-- migrate:down", 1)[1].strip()


def _probe_file(select_sql: str) -> str:
    """A realistic canonical file for a throwaway probe mart with a unique key ``k``."""
    return render_canonical(
        DbObject(
            kind="matview",
            schema="marts",
            name="_rt_probe",
            definition=f" SELECT {select_sql};",
            index_def="CREATE UNIQUE INDEX _rt_probe_pk ON marts._rt_probe USING btree (k)",
        )
    )


def _rendered(conn: psycopg.Connection, name: str) -> str | None:
    for o in read_live_objects(conn):
        if o.name == name:
            return render_canonical(o)
    return None


def test_committed_canonical_files_converge_with_live_objects(conn: psycopg.Connection) -> None:
    # AC#1: on a from-zero DB, every object (matview, view, function) matches
    # its file and every file a live object.
    div = divergence(conn)
    assert div.empty(), div.report()


def test_committed_files_cover_all_three_kinds(conn: psycopg.Connection) -> None:
    # The #426 class rule: the live catalog carries at least one of each kind,
    # so a check that silently dropped a kind could not stay green here.
    kinds = {o.kind for o in read_live_objects(conn)}
    assert kinds == {"matview", "view", "function"}


def test_matview_up_down_up_roundtrip_reverses_and_reconverges(conn: psycopg.Connection) -> None:
    prev = _probe_file("1 AS k")  # previous body (git HEAD)
    curr = _probe_file("1 AS k, 2 AS v")  # current body (edited file)
    migration = render_migration("_rt_probe", curr, prev)
    try:
        conn.execute(prev)  # seed the previous state so up's DROP has a target
        conn.execute(_up(migration))
        up1 = _rendered(conn, "_rt_probe")
        conn.execute(_down(migration))
        down1 = _rendered(conn, "_rt_probe")
        conn.execute(_up(migration))
        up2 = _rendered(conn, "_rt_probe")

        assert up1 is not None and down1 is not None
        assert up1 == up2  # re-converges to the current body after down->up
        assert down1 != up1  # down actually reverted to the previous body
    finally:
        conn.execute("DROP MATERIALIZED VIEW IF EXISTS marts._rt_probe")


def _probe_view_file(select_sql: str) -> str:
    return render_canonical(
        DbObject(
            kind="view", schema="staging", name="_rt_probe_v", definition=f" SELECT {select_sql};"
        )
    )


def test_view_roundtrip_replaces_in_place_and_dependents_survive(
    conn: psycopg.Connection,
) -> None:
    # The whole point of OR REPLACE (#426): stg_seat_interval has matview
    # dependents, so the generated migration must never DROP. Prove a dependent
    # view stays queryable across up -> down -> up.
    prev = _probe_view_file("1 AS k")
    curr = _probe_view_file("2 AS k")  # body-only change, same columns
    migration = render_migration("_rt_probe_v", curr, prev)
    assert "DROP" not in migration.split("-- migrate:down")[0]
    try:
        conn.execute(prev)
        conn.execute("CREATE VIEW staging._rt_probe_dep AS SELECT k FROM staging._rt_probe_v")
        conn.execute(_up(migration))
        assert conn.execute("SELECT k FROM staging._rt_probe_dep").fetchone() == (2,)
        up1 = _rendered(conn, "_rt_probe_v")
        conn.execute(_down(migration))
        assert conn.execute("SELECT k FROM staging._rt_probe_dep").fetchone() == (1,)
        down1 = _rendered(conn, "_rt_probe_v")
        conn.execute(_up(migration))
        assert _rendered(conn, "_rt_probe_v") == up1
        assert down1 != up1
    finally:
        conn.execute("DROP VIEW IF EXISTS staging._rt_probe_dep")
        conn.execute("DROP VIEW IF EXISTS staging._rt_probe_v")


def _probe_fn_file(conn: psycopg.Connection, body: str) -> str:
    # Round the hand-written DDL through the catalog so the canonical file is
    # the deparser's own form, exactly as --bootstrap would store it.
    conn.execute(
        f"CREATE OR REPLACE FUNCTION marts._rt_probe_fn() RETURNS integer "
        f"LANGUAGE sql IMMUTABLE AS $$ SELECT {body} $$"
    )
    rendered = _rendered(conn, "_rt_probe_fn")
    assert rendered is not None
    return rendered


def test_function_roundtrip_replaces_and_reconverges(conn: psycopg.Connection) -> None:
    try:
        prev = _probe_fn_file(conn, "1")
        curr = _probe_fn_file(conn, "2")
        migration = render_migration("_rt_probe_fn", curr, prev)
        assert "DROP" not in migration.split("-- migrate:down")[0]
        conn.execute(_up(migration))
        assert conn.execute("SELECT marts._rt_probe_fn()").fetchone() == (2,)
        conn.execute(_down(migration))
        assert conn.execute("SELECT marts._rt_probe_fn()").fetchone() == (1,)
        conn.execute(_up(migration))
        assert conn.execute("SELECT marts._rt_probe_fn()").fetchone() == (2,)
    finally:
        conn.execute("DROP FUNCTION IF EXISTS marts._rt_probe_fn")


def test_author_new_mart_writes_migration_normalizes_and_converges(
    tmp_path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Exercise the full --name glue (file discovery across dirs, git-HEAD
    # lookup, normalization rewrite, convergence) against throwaway dirs, so
    # the repo tree is untouched.
    migrations = tmp_path / "db" / "migrations"
    shutil.copytree(ms._MIGRATIONS_DIR, migrations)  # real migrations => schema + roles
    # Real canonical files too: the final convergence check is global, so every
    # existing object must keep its file while we add one more.
    shutil.copytree(ms._REPO_ROOT / "db" / "views", tmp_path / "db" / "views")
    shutil.copytree(ms._REPO_ROOT / "db" / "functions", tmp_path / "db" / "functions")
    # A self-consistent fake repo root: dirs live under it (so display paths
    # resolve) and it is not a git repo (so _git_head_file -> None: new-object path).
    monkeypatch.setattr(ms, "_REPO_ROOT", tmp_path)
    monkeypatch.setattr(ms, "_MIGRATIONS_DIR", migrations)

    src = tmp_path / "db" / "views" / "marts" / "rt_author.sql"
    src.write_text(
        render_canonical(
            DbObject(
                kind="matview",
                schema="marts",
                name="rt_author",
                definition=" SELECT 1 as k,2 as v;",  # hand-written, non-deparsed style
                index_def="CREATE UNIQUE INDEX rt_author_pk ON marts.rt_author USING btree (k)",
            )
        ),
        encoding="utf-8",
    )
    before = src.read_text(encoding="utf-8")

    assert ms._run_author("rt_author") == 0  # returns 0 only when it converges
    after = src.read_text(encoding="utf-8")
    assert after != before  # file normalized to the deparser's own form
    assert "CREATE MATERIALIZED VIEW marts.rt_author AS" in after
    assert list(migrations.glob("*rt_author.sql"))  # a migration was authored
