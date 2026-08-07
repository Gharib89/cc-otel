"""Unit coverage for the matview_sync pure layer — render + divergence + migration
text (#263).

No database: the DB-backed convergence proof and up->down->up roundtrip live in
tests/integration/test_matview_sync.py.
"""

from __future__ import annotations

import pytest

from tools.matview_sync import (
    DbObject,
    _run_author,
    compute_divergence,
    render_canonical,
    render_migration,
)

_DIM_MODEL = DbObject(
    kind="matview",
    schema="marts",
    name="dim_model",
    definition=" SELECT model AS model_id\n   FROM ids;",
    index_def="CREATE UNIQUE INDEX dim_model_pk ON marts.dim_model USING btree (model_id)",
)

_STG_VIEW = DbObject(
    kind="view",
    schema="staging",
    name="stg_seat_interval",
    definition=" SELECT seat_email,\n    valid_from\n   FROM ref.seat_roster_snapshot;",
)

_MARTS_VIEW = DbObject(
    kind="view",
    schema="marts",
    name="dq_finding_current",
    definition=" SELECT finding_type\n   FROM marts.dq_finding;",
)

_FUNCTION = DbObject(
    kind="function",
    schema="marts",
    name="email_bucket",
    definition=(
        "CREATE OR REPLACE FUNCTION marts.email_bucket(email text)\n"
        " RETURNS text\n LANGUAGE sql\n IMMUTABLE\n"
        "AS $function$ SELECT COALESCE(email, '(unknown)') $function$"
    ),
)


# --- render_canonical ---------------------------------------------------------


def test_render_canonical_wraps_definition_index_and_grant() -> None:
    text = render_canonical(_DIM_MODEL)
    assert (
        "CREATE MATERIALIZED VIEW marts.dim_model AS\n SELECT model AS model_id\n   FROM ids;"
    ) in text
    assert "CREATE UNIQUE INDEX dim_model_pk ON marts.dim_model USING btree (model_id);" in text
    assert "GRANT SELECT ON marts.dim_model TO cc_otel_read;" in text
    # A header comment names the mart and points at the regen command.
    assert text.startswith("-- Canonical definition for marts.dim_model.")
    assert "--name dim_model" in text
    # Ends with exactly one trailing newline.
    assert text.endswith("TO cc_otel_read;\n")
    assert not text.endswith("\n\n")


def test_render_canonical_is_deterministic() -> None:
    assert render_canonical(_DIM_MODEL) == render_canonical(_DIM_MODEL)


def test_render_canonical_staging_view_uses_or_replace_and_no_grant() -> None:
    text = render_canonical(_STG_VIEW)
    assert (
        "CREATE OR REPLACE VIEW staging.stg_seat_interval AS\n SELECT seat_email,\n"
        "    valid_from\n   FROM ref.seat_roster_snapshot;"
    ) in text
    assert text.startswith("-- Canonical definition for staging.stg_seat_interval.")
    assert "pg_views.definition" in text  # the header names the catalog --check reads
    assert "--name stg_seat_interval" in text
    assert "GRANT" not in text  # staging views carry no reader grant
    assert "MATERIALIZED" not in text
    assert "UNIQUE INDEX" not in text
    assert text.endswith(";\n") and not text.endswith("\n\n")


def test_render_canonical_staging_matview_would_carry_no_grant() -> None:
    # ADR-0026: the grant rule keys on schema, not kind — a staging matview
    # (none exists today) must not render a grant that would never be live.
    obj = DbObject(
        kind="matview",
        schema="staging",
        name="stg_probe_mv",
        definition=" SELECT 1 AS k;",
        index_def="CREATE UNIQUE INDEX stg_probe_mv_pk ON staging.stg_probe_mv USING btree (k)",
    )
    assert "GRANT" not in render_canonical(obj)


def test_render_canonical_marts_view_carries_the_reader_grant() -> None:
    text = render_canonical(_MARTS_VIEW)
    assert "CREATE OR REPLACE VIEW marts.dq_finding_current AS\n SELECT finding_type" in text
    assert "GRANT SELECT ON marts.dq_finding_current TO cc_otel_read;\n" in text
    assert text.endswith("TO cc_otel_read;\n")


def test_render_canonical_function_embeds_functiondef_with_semicolon() -> None:
    text = render_canonical(_FUNCTION)
    assert text.startswith("-- Canonical definition for marts.email_bucket.")
    assert "pg_get_functiondef()" in text  # the header names the catalog --check reads
    # The pg_get_functiondef output is embedded verbatim, terminated for SQL.
    assert "CREATE OR REPLACE FUNCTION marts.email_bucket(email text)\n" in text
    assert text.endswith("$function$;\n")
    assert "GRANT" not in text  # functions carry no grant


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
    sql = render_migration("dim_model", _CURRENT, None)
    up, down = sql.split("-- migrate:down", 1)
    assert "DROP MATERIALIZED VIEW marts.dim_model;" not in up
    assert "DROP MATERIALIZED VIEW IF EXISTS marts.dim_model;" in down


_VIEW_CURRENT = (
    "-- Canonical definition for staging.stg_probe.\n"
    "CREATE OR REPLACE VIEW staging.stg_probe AS\n SELECT 2;\n"
)
_VIEW_PREVIOUS = (
    "-- Canonical definition for staging.stg_probe.\n"
    "CREATE OR REPLACE VIEW staging.stg_probe AS\n SELECT 1;\n"
)


def test_render_migration_view_redefinition_replaces_without_drop() -> None:
    # No DROP either way: stg_seat_interval has matview dependents, and a
    # CASCADE would take the marts with it (#426).
    sql = render_migration("stg_probe", _VIEW_CURRENT, _VIEW_PREVIOUS)
    up, down = sql.split("-- migrate:down", 1)
    assert "DROP" not in sql
    assert "CREATE OR REPLACE VIEW staging.stg_probe AS\n SELECT 2;" in up
    assert "CREATE OR REPLACE VIEW staging.stg_probe AS\n SELECT 1;" in down


def test_render_migration_new_view_down_drops_if_exists() -> None:
    sql = render_migration("stg_probe", _VIEW_CURRENT, None)
    up, down = sql.split("-- migrate:down", 1)
    assert "DROP" not in up
    assert "DROP VIEW IF EXISTS staging.stg_probe;" in down


def test_render_migration_view_down_drops_and_recreates_when_flagged() -> None:
    # ADR-0026's no-DROP rule guards the *up* — a forward deploy must not take
    # dependents with it. A down that has to narrow the column list has no OR
    # REPLACE form at all, so it carries the DROP the up still never does (#437).
    sql = render_migration("stg_probe", _VIEW_CURRENT, _VIEW_PREVIOUS, down_drops=True)
    up, down = sql.split("-- migrate:down", 1)
    assert "DROP" not in up
    assert down.strip().startswith("DROP VIEW staging.stg_probe;")
    assert "CREATE OR REPLACE VIEW staging.stg_probe AS\n SELECT 1;" in down


def test_render_migration_down_drops_flag_is_inert_for_a_new_object() -> None:
    # Nothing to restore, so the down stays the plain DROP ... IF EXISTS.
    sql = render_migration("stg_probe", _VIEW_CURRENT, None, down_drops=True)
    down = sql.split("-- migrate:down", 1)[1]
    assert "DROP VIEW IF EXISTS staging.stg_probe;" in down
    assert "CREATE OR REPLACE VIEW staging.stg_probe" not in down


def test_render_migration_down_drops_flag_is_inert_for_a_matview() -> None:
    # A matview down already is DROP + CREATE; the flag must not double it.
    sql = render_migration("dim_model", _CURRENT, _PREVIOUS, down_drops=True)
    down = sql.split("-- migrate:down", 1)[1]
    assert down.count("DROP MATERIALIZED VIEW marts.dim_model;") == 1


_FN_CURRENT = (
    "-- Canonical definition for marts.probe_fn.\n"
    "CREATE OR REPLACE FUNCTION marts.probe_fn()\n RETURNS void\n LANGUAGE sql\n"
    "AS $function$ SELECT $function$;\n"
)
_FN_PREVIOUS = (
    "-- Canonical definition for marts.probe_fn.\n"
    "CREATE OR REPLACE FUNCTION marts.probe_fn()\n RETURNS integer\n LANGUAGE sql\n"
    "AS $function$ SELECT 1 $function$;\n"
)


def test_render_migration_new_function_down_drops_function_if_exists() -> None:
    sql = render_migration("probe_fn", _FN_CURRENT, None)
    up, down = sql.split("-- migrate:down", 1)
    assert "CREATE OR REPLACE FUNCTION marts.probe_fn()" in up
    assert "DROP FUNCTION IF EXISTS marts.probe_fn;" in down


def test_render_migration_function_down_drops_and_recreates_when_flagged() -> None:
    sql = render_migration("probe_fn", _FN_CURRENT, _FN_PREVIOUS, down_drops=True)
    up, down = sql.split("-- migrate:down", 1)
    assert "DROP" not in up
    assert down.strip().startswith("DROP FUNCTION marts.probe_fn;")
    assert "RETURNS integer" in down


def test_render_migration_rejects_file_whose_create_line_names_another_object() -> None:
    with pytest.raises(ValueError, match="creates staging.stg_probe, not other_name"):
        render_migration("other_name", _VIEW_CURRENT, None)


def test_render_migration_rejects_file_without_a_create_line() -> None:
    with pytest.raises(ValueError, match="no recognizable CREATE line"):
        render_migration("stg_probe", "-- just a comment\n", None)


# --- disk layout ----------------------------------------------------------------


def _seed_canonical_tree(root) -> None:
    (root / "db" / "views" / "marts").mkdir(parents=True)
    (root / "db" / "views" / "staging").mkdir(parents=True)
    (root / "db" / "functions" / "marts").mkdir(parents=True)
    (root / "db" / "views" / "marts" / "dim_model.sql").write_text("M\n", encoding="utf-8")
    (root / "db" / "views" / "staging" / "stg_probe.sql").write_text("V\n", encoding="utf-8")
    (root / "db" / "functions" / "marts" / "refresh_all.sql").write_text("F\n", encoding="utf-8")


def test_disk_files_spans_views_and_functions_dirs(tmp_path, monkeypatch) -> None:
    import tools.matview_sync as ms

    _seed_canonical_tree(tmp_path)
    monkeypatch.setattr(ms, "_REPO_ROOT", tmp_path)
    assert ms.disk_files() == {"dim_model": "M\n", "stg_probe": "V\n", "refresh_all": "F\n"}


def test_disk_files_rejects_duplicate_stems_across_dirs(tmp_path, monkeypatch) -> None:
    import tools.matview_sync as ms

    _seed_canonical_tree(tmp_path)
    (tmp_path / "db" / "views" / "staging" / "dim_model.sql").write_text("DUP\n", encoding="utf-8")
    monkeypatch.setattr(ms, "_REPO_ROOT", tmp_path)
    with pytest.raises(RuntimeError, match="duplicate canonical file name"):
        ms.disk_files()


# --- slug validation ----------------------------------------------------------


@pytest.mark.parametrize("slug", ["../evil", "a/b", "Bad", "9x", "with space", "drop;--"])
def test_run_author_rejects_unsafe_slug(slug: str) -> None:
    # Validation fails fast before any file/DB access, so no Docker is needed.
    assert _run_author(slug) == 1
