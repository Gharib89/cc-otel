"""DB-backed proof for the canonical mart definition files + generator (#263).

Two guarantees the pure unit layer can't give:
- every committed canonical file converges with its live mart on a from-zero DB
  (bidirectional — the `--check` gate contract);
- a generated migration's up->down->up roundtrip reverses and re-converges, which
  is the first coverage the *down* bodies have ever had (#254).
"""

from __future__ import annotations

import shutil

import psycopg
import pytest

from tools import matview_sync as ms
from tools.matview_sync import (
    Mart,
    divergence,
    read_live_marts,
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
        Mart(
            name="_rt_probe",
            definition=f" SELECT {select_sql};",
            index_def="CREATE UNIQUE INDEX _rt_probe_pk ON marts._rt_probe USING btree (k)",
        )
    )


def _probe_rendered(conn: psycopg.Connection) -> str | None:
    for m in read_live_marts(conn):
        if m.name == "_rt_probe":
            return render_canonical(m)
    return None


def test_committed_canonical_files_converge_with_marts(conn: psycopg.Connection) -> None:
    # AC#1: on a from-zero DB, every mart matches its file and every file a mart.
    div = divergence(conn)
    assert div.empty(), div.report()


def test_up_down_up_roundtrip_reverses_and_reconverges(conn: psycopg.Connection) -> None:
    prev = _probe_file("1 AS k")  # previous body (git HEAD)
    curr = _probe_file("1 AS k, 2 AS v")  # current body (edited file)
    migration = render_migration("_rt_probe", curr, prev)
    try:
        conn.execute(prev)  # seed the previous state so up's DROP has a target
        conn.execute(_up(migration))
        up1 = _probe_rendered(conn)
        conn.execute(_down(migration))
        down1 = _probe_rendered(conn)
        conn.execute(_up(migration))
        up2 = _probe_rendered(conn)

        assert up1 is not None and down1 is not None
        assert up1 == up2  # re-converges to the current body after down->up
        assert down1 != up1  # down actually reverted to the previous body
    finally:
        conn.execute("DROP MATERIALIZED VIEW IF EXISTS marts._rt_probe")


def test_author_new_mart_writes_migration_normalizes_and_converges(
    tmp_path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Exercise the full --name glue (file write, git-HEAD lookup, normalization
    # rewrite, convergence) against throwaway dirs, so the repo tree is untouched.
    migrations = tmp_path / "db" / "migrations"
    shutil.copytree(ms._MIGRATIONS_DIR, migrations)  # real migrations => schema + roles
    # Real canonical files too: the final convergence check is global, so the 16
    # existing marts must keep their files while we add a 17th.
    views = tmp_path / "db" / "views" / "marts"
    shutil.copytree(ms._VIEWS_DIR, views)
    # A self-consistent fake repo root: dirs live under it (so display paths
    # resolve) and it is not a git repo (so _git_head_file -> None: new-mart path).
    monkeypatch.setattr(ms, "_REPO_ROOT", tmp_path)
    monkeypatch.setattr(ms, "_MIGRATIONS_DIR", migrations)
    monkeypatch.setattr(ms, "_VIEWS_DIR", views)

    src = views / "_rt_author.sql"
    src.write_text(
        render_canonical(
            Mart(
                name="_rt_author",
                definition=" SELECT 1 as k,2 as v;",  # hand-written, non-deparsed style
                index_def="CREATE UNIQUE INDEX _rt_author_pk ON marts._rt_author USING btree (k)",
            )
        ),
        encoding="utf-8",
    )
    before = src.read_text(encoding="utf-8")

    assert ms._run_author("_rt_author") == 0  # returns 0 only when it converges
    after = src.read_text(encoding="utf-8")
    assert after != before  # file normalized to the deparser's own form
    assert "CREATE MATERIALIZED VIEW marts._rt_author AS" in after
    assert list(migrations.glob("*_rt_author.sql"))  # a migration was authored
