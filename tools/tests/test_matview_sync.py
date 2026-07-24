"""Unit coverage for the matview_sync pure layer — render + divergence + migration
text (#263).

No database: the DB-backed convergence proof and up->down->up roundtrip live in
tests/integration/test_matview_sync.py.
"""

from __future__ import annotations

from tools.matview_sync import (
    Mart,
    compute_divergence,
    render_canonical,
    render_migration,
)

_DIM_MODEL = Mart(
    name="dim_model",
    definition=" SELECT model AS model_id\n   FROM ids;",
    index_def="CREATE UNIQUE INDEX dim_model_pk ON marts.dim_model USING btree (model_id)",
)


# --- render_canonical ---------------------------------------------------------


def test_render_canonical_wraps_definition_index_and_grant() -> None:
    text = render_canonical(_DIM_MODEL)
    assert (
        "CREATE MATERIALIZED VIEW marts.dim_model AS\n SELECT model AS model_id\n   FROM ids;"
    ) in text
    assert (
        "CREATE UNIQUE INDEX dim_model_pk ON marts.dim_model USING btree (model_id);" in text
    )
    assert "GRANT SELECT ON marts.dim_model TO cc_otel_read;" in text
    # A header comment names the mart and points at the regen command.
    assert text.startswith("-- Canonical definition for marts.dim_model.")
    assert "--name dim_model" in text
    # Ends with exactly one trailing newline.
    assert text.endswith("TO cc_otel_read;\n")
    assert not text.endswith("\n\n")


def test_render_canonical_is_deterministic() -> None:
    assert render_canonical(_DIM_MODEL) == render_canonical(_DIM_MODEL)


# --- compute_divergence -------------------------------------------------------


def test_compute_divergence_empty_when_rendered_matches_disk() -> None:
    d = compute_divergence({"a": "X\n", "b": "Y\n"}, {"a": "X\n", "b": "Y\n"})
    assert d.empty()


def test_compute_divergence_flags_missing_orphan_and_mismatch() -> None:
    rendered = {"live_and_file": "SAME\n", "live_only": "L\n", "edited": "NEW\n"}
    disk = {"live_and_file": "SAME\n", "file_only": "F\n", "edited": "OLD\n"}
    d = compute_divergence(rendered, disk)
    assert not d.empty()
    assert d.missing_files == ["live_only"]  # live mart, no on-disk file
    assert d.orphan_files == ["file_only"]  # on-disk file, no live mart
    assert d.mismatched == ["edited"]  # file edited without a migration


def test_compute_divergence_report_names_each_bucket() -> None:
    d = compute_divergence({"x": "A\n"}, {"y": "B\n"})
    report = d.report()
    assert "x" in report and "y" in report


# --- render_migration ---------------------------------------------------------

_HEAD = "-- Canonical definition for marts.dim_model.\n"
_CURRENT = _HEAD + "CREATE MATERIALIZED VIEW marts.dim_model AS\n SELECT 2;\n"
_PREVIOUS = _HEAD + "CREATE MATERIALIZED VIEW marts.dim_model AS\n SELECT 1;\n"


def test_render_migration_redefinition_drops_then_creates_both_ways() -> None:
    sql = render_migration("dim_model", _CURRENT, _PREVIOUS)
    up, down = sql.split("-- migrate:down", 1)
    assert up.startswith("-- migrate:up\n-- matview_sync: dim_model\n")
    # up: DROP the old, then the current file body verbatim.
    assert "DROP MATERIALIZED VIEW marts.dim_model;" in up
    assert "CREATE MATERIALIZED VIEW marts.dim_model AS\n SELECT 2;" in up
    # down: DROP, then the PREVIOUS body verbatim (from git HEAD).
    assert "DROP MATERIALIZED VIEW marts.dim_model;" in down
    assert "CREATE MATERIALIZED VIEW marts.dim_model AS\n SELECT 1;" in down
    assert sql.endswith("\n")


def test_render_migration_has_exactly_one_up_and_down_marker() -> None:
    sql = render_migration("dim_model", _CURRENT, _PREVIOUS)
    assert sql.count("-- migrate:up") == 1
    assert sql.count("-- migrate:down") == 1


def test_render_migration_new_mart_has_no_leading_drop_and_down_drops_if_exists() -> None:
    sql = render_migration("brand_new", _CURRENT, None)
    up, down = sql.split("-- migrate:down", 1)
    assert "DROP MATERIALIZED VIEW marts.brand_new;" not in up
    assert "DROP MATERIALIZED VIEW IF EXISTS marts.brand_new;" in down
