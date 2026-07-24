"""Shared mart-rule functions (#264): marts.email_bucket / marts.prefer_itworx.

The two cross-cutting rules that were duplicated as string literals across mart
bodies now live once as scalar SQL functions. These tests pin the two acceptance
criteria unique to the extraction: the functions reproduce the old inline
behavior exactly, and — declared IMMUTABLE with single-expression BEGIN ATOMIC
bodies — PG16 inlines them into a mart's plan (no residual function call), so
refresh cost is unchanged. The row-level equivalence of the affected marts is
covered by test_marts.py, which is unchanged by this refactor.
"""

from __future__ import annotations


def one(conn, sql):
    return conn.execute(sql).fetchone()


def test_email_bucket_maps_null_and_passes_through(conn):
    # NULL -> '(unknown)'; any real value passes through unchanged.
    assert one(conn, "SELECT marts.email_bucket(NULL)") == ("(unknown)",)
    assert one(conn, "SELECT marts.email_bucket('a@x.com')") == ("a@x.com",)


def test_prefer_itworx_tie_break(conn):
    # Prefer an itworx address; else fall through to COALESCE of the two args.
    assert one(conn, "SELECT marts.prefer_itworx('b@x.com', 'c@itworx.com')") == ("c@itworx.com",)
    assert one(conn, "SELECT marts.prefer_itworx('a@itworx.com', 'b@itworx.com')") == (
        "a@itworx.com",
    )
    assert one(conn, "SELECT marts.prefer_itworx('a@x.com', 'b@y.com')") == ("a@x.com",)
    assert one(conn, "SELECT marts.prefer_itworx(NULL, 'b@y.com')") == ("b@y.com",)
    assert one(conn, "SELECT marts.prefer_itworx(NULL, NULL)") == (None,)


def test_functions_inline_into_query_plan(conn):
    # A representative mart expression: both rules composed. IMMUTABLE + single
    # BEGIN ATOMIC expression => PG16 inlines them, so the plan shows the raw
    # COALESCE/CASE and no function call remains (identical cost to hand-inlined
    # SQL — the whole point of the extraction).
    plan = "\n".join(
        r[0]
        for r in conn.execute(
            "EXPLAIN (VERBOSE, COSTS OFF) "
            "SELECT marts.email_bucket(marts.prefer_itworx(a, b)) "
            "FROM (VALUES ('x@itworx.com', NULL), (NULL, NULL)) AS t(a, b)"
        ).fetchall()
    )
    assert "email_bucket" not in plan
    assert "prefer_itworx" not in plan
    assert "COALESCE" in plan
    assert "CASE" in plan
