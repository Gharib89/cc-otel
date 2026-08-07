"""DB-backed proof for the canonical definition files + generator (#263, #426).

Guarantees the pure unit layer can't give:
- every committed canonical file converges with its live object on a from-zero
  DB (bidirectional — the `--check` gate contract), across all three kinds;
- a generated migration's up->down->up roundtrip reverses and re-converges,
  per kind — including that a plain view's CREATE OR REPLACE leaves its
  dependents standing (#426's reason for never generating a DROP).

A view's or function's down restores the previous body with CREATE OR REPLACE
where Postgres allows it, and falls back to DROP + CREATE where it does not — a
column-adding view amendment, a signature-changing function (#437). The
generator picks by probing, so the proof has to *execute* the generated down,
not assert on its text; the tests below do both shapes and the case where
neither runs (a dependent blocks the DROP), which is the loud hand-author
escape hatch.
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


def test_column_adding_view_down_is_unrunnable_without_the_drop(
    conn: psycopg.Connection,
) -> None:
    # The #437 defect itself, pinned: OR REPLACE can append a column but never
    # remove one, so restoring the previous body is rejected. This is what makes
    # the fallback necessary — and it is why the down must be *executed* here,
    # not asserted on as text.
    prev = _probe_view_file("1 AS k")
    curr = _probe_view_file("1 AS k, 2 AS v")  # the up appends a column
    migration = render_migration("_rt_probe_v", curr, prev)
    try:
        conn.execute(prev)
        conn.execute(_up(migration))
        with pytest.raises(psycopg.errors.InvalidTableDefinition):
            conn.execute(_down(migration))
    finally:
        conn.execute("DROP VIEW IF EXISTS staging._rt_probe_v")


def test_column_adding_view_down_runs_with_the_drop_fallback(conn: psycopg.Connection) -> None:
    prev = _probe_view_file("1 AS k")
    curr = _probe_view_file("1 AS k, 2 AS v")
    migration = render_migration("_rt_probe_v", curr, prev, down_drops=True)
    try:
        conn.execute(prev)
        expected_prev = _rendered(conn, "_rt_probe_v")
        conn.execute(_up(migration))
        up1 = _rendered(conn, "_rt_probe_v")
        conn.execute(_down(migration))  # the assertion is that this runs at all
        assert _rendered(conn, "_rt_probe_v") == expected_prev
        assert up1 != expected_prev
    finally:
        conn.execute("DROP VIEW IF EXISTS staging._rt_probe_v")


def _seed_amended_view(conn: psycopg.Connection, prev: str, curr: str) -> None:
    """Put the DB in the state a rollback would meet: previous seeded, up applied."""
    conn.execute(prev)
    conn.execute(_up(render_migration("_rt_probe_v", curr, prev)))


def test_choose_down_shape_keeps_or_replace_for_a_body_only_amendment(
    conn: psycopg.Connection,
) -> None:
    # The common case must not regress into a DROP: OR REPLACE restores a
    # same-column-list body fine, so the probe has to pick it (#437).
    prev = _probe_view_file("1 AS k")
    curr = _probe_view_file("2 AS k")
    try:
        _seed_amended_view(conn, prev, curr)
        assert ms._choose_down_shape(conn, "_rt_probe_v", curr, prev) is False
        # And the probe left the DB exactly where it found it.
        assert _rendered(conn, "_rt_probe_v") == curr
    finally:
        conn.execute("DROP VIEW IF EXISTS staging._rt_probe_v")


def test_choose_down_shape_falls_back_to_drop_for_a_column_adding_amendment(
    conn: psycopg.Connection,
) -> None:
    prev = _probe_view_file("1 AS k")
    curr = _probe_view_file("1 AS k, 2 AS v")
    try:
        _seed_amended_view(conn, prev, curr)
        assert ms._choose_down_shape(conn, "_rt_probe_v", curr, prev) is True
        assert _rendered(conn, "_rt_probe_v") is not None  # probes rolled back
    finally:
        conn.execute("DROP VIEW IF EXISTS staging._rt_probe_v")


def test_choose_down_shape_returns_none_when_a_dependent_blocks_the_drop(
    conn: psycopg.Connection,
) -> None:
    # Neither shape runs: OR REPLACE cannot narrow the column list, and the DROP
    # that would is refused by a dependent. _run_author turns this into the same
    # loud hand-author instruction ADR-0026 already gives for a structural up.
    prev = _probe_view_file("1 AS k")
    curr = _probe_view_file("1 AS k, 2 AS v")
    try:
        _seed_amended_view(conn, prev, curr)
        conn.execute("CREATE VIEW staging._rt_probe_dep AS SELECT k FROM staging._rt_probe_v")
        assert ms._choose_down_shape(conn, "_rt_probe_v", curr, prev) is None
        # The failed DROP probe rolled back, so the dependent is still standing.
        assert conn.execute("SELECT k FROM staging._rt_probe_dep").fetchone() == (1,)
    finally:
        conn.execute("DROP VIEW IF EXISTS staging._rt_probe_dep")
        conn.execute("DROP VIEW IF EXISTS staging._rt_probe_v")


def _probe_fn_file(conn: psycopg.Connection, body: str, returns: str = "integer") -> str:
    # Round the hand-written DDL through the catalog so the canonical file is
    # the deparser's own form, exactly as --bootstrap would store it. The DROP
    # lets a caller vary the signature, which OR REPLACE alone cannot (#437).
    conn.execute("DROP FUNCTION IF EXISTS marts._rt_probe_fn()")
    conn.execute(
        f"CREATE OR REPLACE FUNCTION marts._rt_probe_fn() RETURNS {returns} "
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


def test_signature_changing_function_down_runs_with_the_drop_fallback(
    conn: psycopg.Connection,
) -> None:
    # A function's OR REPLACE restriction is symmetric (a return-type change is
    # rejected in both directions), so the matching up is a hand-authored
    # cascade either way. What the fallback buys is a down that *runs* instead
    # of a decorative one — the same guarantee as the view case.
    try:
        prev = _probe_fn_file(conn, "1")  # RETURNS integer
        curr = _probe_fn_file(conn, "1", returns="bigint")  # signature changed
        with pytest.raises(psycopg.errors.InvalidFunctionDefinition):
            conn.execute(_down(render_migration("_rt_probe_fn", curr, prev)))
        migration = render_migration("_rt_probe_fn", curr, prev, down_drops=True)
        conn.execute(_down(migration))  # the assertion is that this runs at all
        assert _rendered(conn, "_rt_probe_fn") == prev
    finally:
        conn.execute("DROP FUNCTION IF EXISTS marts._rt_probe_fn")


def test_main_check_exits_zero_against_a_migrated_db(pg_url: str) -> None:
    # The --check gate through the real CLI — first coverage for main -> _run_check
    # (#426 deliverable). --database-url skips the self-spun container.
    assert ms.main(["--check", "--database-url", pg_url]) == 0


def test_main_check_exits_one_on_divergence(
    pg_url: str, tmp_path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # An empty canonical tree diverges from every live object: exit 1, report on
    # stderr — the gate contract CI and the local gate act on.
    monkeypatch.setattr(ms, "_REPO_ROOT", tmp_path)
    assert ms.main(["--check", "--database-url", pg_url]) == 1
    assert "no canonical file" in capsys.readouterr().err


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


def test_author_picks_the_drop_down_for_a_column_adding_view_amendment(
    tmp_path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The #437 deliverable end to end: --name probes the candidate down against
    # the up state and falls back on its own — the author passes no flag.
    migrations = tmp_path / "db" / "migrations"
    shutil.copytree(ms._MIGRATIONS_DIR, migrations)
    shutil.copytree(ms._REPO_ROOT / "db" / "views", tmp_path / "db" / "views")
    shutil.copytree(ms._REPO_ROOT / "db" / "functions", tmp_path / "db" / "functions")
    monkeypatch.setattr(ms, "_REPO_ROOT", tmp_path)
    monkeypatch.setattr(ms, "_MIGRATIONS_DIR", migrations)

    def _file(select_sql: str) -> str:
        return render_canonical(
            DbObject(
                kind="view", schema="staging", name="rt_amend", definition=f" SELECT {select_sql};"
            )
        )

    previous = _file("1 AS k")
    (tmp_path / "db" / "views" / "staging" / "rt_amend.sql").write_text(
        _file("1 AS k,\n    2 AS v"), encoding="utf-8"
    )
    # The amendment path needs a git-HEAD body; tmp_path is deliberately not a repo.
    monkeypatch.setattr(ms, "_git_head_file", lambda path: previous)

    assert ms._run_author("rt_amend") == 0
    written = next(iter(migrations.glob("*rt_amend.sql"))).read_text(encoding="utf-8")
    assert "DROP" not in _up(written)  # ADR-0026's no-DROP rule still binds the up
    assert _down(written).startswith("DROP VIEW staging.rt_amend;")
    assert "CREATE OR REPLACE VIEW staging.rt_amend AS\n SELECT 1 AS k;" in _down(written)


def test_author_removes_the_migration_when_no_down_shape_runs(
    tmp_path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Neither shape runs, so --name must leave nothing behind: a migration whose
    # down cannot run is exactly the decorative artefact #437 set out to end,
    # and a stray file in db/migrations/ would reach the schema-drift gate.
    migrations = tmp_path / "db" / "migrations"
    shutil.copytree(ms._MIGRATIONS_DIR, migrations)
    shutil.copytree(ms._REPO_ROOT / "db" / "views", tmp_path / "db" / "views")
    shutil.copytree(ms._REPO_ROOT / "db" / "functions", tmp_path / "db" / "functions")
    monkeypatch.setattr(ms, "_REPO_ROOT", tmp_path)
    monkeypatch.setattr(ms, "_MIGRATIONS_DIR", migrations)

    def _file(select_sql: str) -> str:
        return render_canonical(
            DbObject(
                kind="view", schema="staging", name="rt_block", definition=f" SELECT {select_sql};"
            )
        )

    previous = _file("1 AS k")
    (tmp_path / "db" / "views" / "staging" / "rt_block.sql").write_text(
        _file("1 AS k,\n    2 AS v"), encoding="utf-8"
    )
    # Sorts last, so the dependent exists by the time the probe runs — and the
    # DROP fallback is refused, leaving no runnable down at all.
    (migrations / "99999999999999_rt_block_dep.sql").write_text(
        "-- migrate:up\n-- noqa: disable=all\n\n"
        "CREATE VIEW staging.rt_block_dep AS SELECT k FROM staging.rt_block;\n"
        "\n-- migrate:down\n\nDROP VIEW IF EXISTS staging.rt_block_dep;\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(ms, "_git_head_file", lambda path: previous)

    assert ms._run_author("rt_block") == 1
    assert not list(migrations.glob("*_rt_block.sql"))
