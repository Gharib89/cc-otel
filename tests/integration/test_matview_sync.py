"""DB-backed proof for the canonical mart definition files + generator (#263).

Two guarantees the pure unit layer can't give:
- every committed canonical file converges with its live mart on a from-zero DB
  (bidirectional — the `--check` gate contract);
- a generated migration's up->down->up roundtrip reverses and re-converges, which
  is the first coverage the *down* bodies have ever had (#254).
"""

from __future__ import annotations

import psycopg

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
