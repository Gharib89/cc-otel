"""Prove — and close — the delta between ``column_spec`` and the migrations (#167).

``column_spec`` is the authoritative attr -> column -> status catalogue;
``meta.column_registry`` + the ``raw.*`` DDL are its deployed projection. This
tool is the convergence gate between the two.

    uv run python -m tools.spec_sync --check [--database-url URL]
        Gate: exit 1 on any spec <-> migrations delta, or on any metric-name/enum
        literal in ``db/migrations/*.sql`` absent from the spec catalog (the
        mart-literal lint, #168). Connects to an already-migrated DB
        (``--database-url`` / ``$DATABASE_URL``) or, with neither, spins its own
        throwaway ``postgres:16`` and applies migrations.

    uv run python -m tools.spec_sync --name <slug>
        Author: diff the spec against a from-zero DB, write a migration closing
        the delta (``ADD COLUMN`` / registry ``INSERT`` + a down section), apply
        it, verify the delta is empty, regenerate schema.sql.

    uv run python -m tools.spec_sync --allow-destructive --name <slug>
        Opt in to ``DROP COLUMN`` deltas (a column dropped from the spec).

Renames and type changes are refused — hand-author the migration + spec edit;
the gate proves convergence. A DB *ahead* of the spec (orphan registry rows) is
a spec-edit fix, never a generated ``DELETE``.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import NamedTuple

import psycopg
from cc_otel_sink.column_spec import (
    COLUMN_SPEC,
    ENUM_VALUES,
    METRIC_NAMES,
    ColumnSpec,
    RegistryRow,
    registry_rows,
)

from tools import _ephemeral_pg

_REPO_ROOT = Path(__file__).resolve().parents[1]
_MIGRATIONS_DIR = _REPO_ROOT / "db" / "migrations"
_CONTAINER = "cc-otel-spec-sync"

# Spec DataType -> information_schema.columns.data_type (raw-table check only;
# the registry stores the spec's own type string verbatim).
_PG_TYPE = {
    "TEXT": "text",
    "UUID": "uuid",
    "TIMESTAMPTZ": "timestamp with time zone",
    "BIGINT": "bigint",
    "INTEGER": "integer",
    "SMALLINT": "smallint",
    "DOUBLE PRECISION": "double precision",
    "BOOLEAN": "boolean",
}

_REGISTRY_COLS = (
    "signal",
    "signal_name",
    "attr_path",
    "status",
    "column_name",
    "data_type",
    "description",
    "useful_for",
    "decided_at",
    "notes",
)


# --- spec-side projections ----------------------------------------------------


def spec_registry_rows(spec: tuple[ColumnSpec, ...] = COLUMN_SPEC) -> set[RegistryRow]:
    """The registry rows the spec expects, keyed for set comparison.

    The projection lives once, in ``column_spec.registry_rows`` — this only lifts
    it into a set for diffing.
    """
    return set(registry_rows(spec))


def spec_raw_columns(spec: tuple[ColumnSpec, ...] = COLUMN_SPEC) -> dict[str, dict[str, str]]:
    """``{table: {column: pg_type}}`` the spec expects in the ``raw.*`` DDL."""
    out: dict[str, dict[str, str]] = {"metrics": {}, "events": {}}
    for r in spec:
        if r.status == "promoted" and r.signal in out and r.column_name and r.data_type:
            out[r.signal][r.column_name] = _PG_TYPE[r.data_type]
    return out


# --- db-side readers ----------------------------------------------------------


def db_registry_rows(conn: psycopg.Connection) -> set[RegistryRow]:
    cols = ", ".join(_REGISTRY_COLS)
    with conn.cursor() as cur:
        cur.execute(f"SELECT {cols} FROM meta.column_registry")
        rows = cur.fetchall()
    out: set[RegistryRow] = set()
    for row in rows:
        decided = row[8].isoformat() if row[8] is not None else ""
        out.add((row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], decided, row[9]))
    return out


def db_raw_columns(conn: psycopg.Connection, table: str) -> dict[str, str]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT column_name, data_type FROM information_schema.columns "
            "WHERE table_schema = 'raw' AND table_name = %s",
            (table,),
        )
        return {name: dtype for name, dtype in cur.fetchall()}


# --- delta --------------------------------------------------------------------


@dataclass
class Delta:
    missing_rows: list[RegistryRow] = field(default_factory=list)  # in spec, not DB
    orphan_rows: list[RegistryRow] = field(default_factory=list)  # in DB, not spec
    missing_columns: list[tuple[str, str, str]] = field(default_factory=list)  # (table, col, type)
    orphan_columns: list[tuple[str, str]] = field(default_factory=list)  # table, col
    mismatched_columns: list[tuple[str, str, str, str]] = field(default_factory=list)

    def empty(self) -> bool:
        return not (
            self.missing_rows
            or self.orphan_rows
            or self.missing_columns
            or self.orphan_columns
            or self.mismatched_columns
        )

    def report(self) -> str:
        lines: list[str] = []
        for r in sorted(self.missing_rows):
            lines.append(f"  registry row in spec, missing from DB: {r[:4]}")
        for r in sorted(self.orphan_rows):
            lines.append(f"  registry row in DB, absent from spec (fix = spec edit): {r[:4]}")
        for table, col, dtype in sorted(self.missing_columns):
            lines.append(f"  raw.{table} column in spec, missing from DB: {col} {dtype}")
        for table, col in sorted(self.orphan_columns):
            lines.append(f"  raw.{table} column in DB, absent from spec (destructive): {col}")
        for table, col, db_t, spec_t in sorted(self.mismatched_columns):
            lines.append(f"  raw.{table}.{col} type: DB={db_t!r} spec={spec_t!r}")
        return "\n".join(lines)


def compute_delta(
    conn: psycopg.Connection,
    spec: tuple[ColumnSpec, ...] = COLUMN_SPEC,
) -> Delta:
    spec_rows = spec_registry_rows(spec)
    db_rows = db_registry_rows(conn)
    delta = Delta(
        missing_rows=sorted(spec_rows - db_rows),
        orphan_rows=sorted(db_rows - spec_rows),
    )
    spec_cols = spec_raw_columns(spec)
    for table, expected in spec_cols.items():
        actual = db_raw_columns(conn, table)
        for col, spec_type in expected.items():
            if col not in actual:
                delta.missing_columns.append((table, col, _spec_ddl_type(spec, table, col)))
            elif actual[col] != spec_type:
                delta.mismatched_columns.append((table, col, actual[col], spec_type))
        for col in actual:
            if col not in expected:
                delta.orphan_columns.append((table, col))
    return delta


def _spec_ddl_type(spec: tuple[ColumnSpec, ...], signal: str, column: str) -> str:
    for r in spec:
        if r.signal == signal and r.column_name == column and r.data_type:
            return r.data_type
    raise ValueError(f"no spec data_type for raw.{signal}.{column}")


# --- migration generation -----------------------------------------------------


def _sql_lit(value: str | None) -> str:
    if value is None:
        return "NULL"
    return "'" + value.replace("'", "''") + "'"


def _insert_row(r: RegistryRow) -> str:
    cols = ", ".join(_REGISTRY_COLS)
    vals = ", ".join(_sql_lit(v) for v in r)
    return f"INSERT INTO meta.column_registry ({cols}) VALUES ({vals});"


def generate_migration(name: str, delta: Delta, *, allow_destructive: bool = False) -> str:
    """Render up/down SQL closing ``delta``. Refuses renames, type changes, and
    (without ``allow_destructive``) column drops."""
    if delta.mismatched_columns:
        raise ValueError(
            "type change refused — hand-author the migration + spec edit: "
            f"{delta.mismatched_columns}"
        )
    if delta.orphan_rows:
        raise ValueError(
            "DB has registry rows absent from the spec; fix is a spec edit, not a "
            f"generated DELETE: {[r[:4] for r in delta.orphan_rows]}"
        )
    if delta.orphan_columns and not allow_destructive:
        raise ValueError(f"column drop needs --allow-destructive: {delta.orphan_columns}")

    up: list[str] = []
    down: list[str] = []
    for table, col, dtype in delta.missing_columns:
        up.append(f"ALTER TABLE raw.{table} ADD COLUMN {col} {dtype};")
        down.append(f"ALTER TABLE raw.{table} DROP COLUMN {col};")
    for table, col in delta.orphan_columns:
        up.append(f"ALTER TABLE raw.{table} DROP COLUMN {col};")
        down.append(f"-- manual: re-add dropped raw.{table}.{col}")
    for r in delta.missing_rows:
        up.append(_insert_row(r))
        down.append(
            "DELETE FROM meta.column_registry WHERE "
            f"signal = {_sql_lit(r[0])} AND signal_name = {_sql_lit(r[1])} "
            f"AND attr_path = {_sql_lit(r[2])};"
        )

    body_up = "\n".join(up) if up else "-- no forward changes"
    body_down = "\n".join(reversed(down)) if down else "-- no rollback changes"
    # sqlfluff lints db/*.sql (pre-commit, and so CI). Registry rows carry prose
    # descriptions on one line, so a generated INSERT/DELETE is long by
    # construction and keeps WHERE on the statement line — waive those two rules
    # here rather than reformat machine-written SQL nobody hand-edits.
    header = f"-- migrate:up\n-- spec_sync: {name}\n-- noqa: disable=LT05,LT14"
    return f"{header}\n\n{body_up}\n\n-- migrate:down\n\n{body_down}\n"


# --- mart-literal lint (#168) -------------------------------------------------
#
# Mart SQL re-encodes metric-name/enum literals verbatim; a typo silently yields
# zero rows in the affected fact. This is a tripwire, not a SQL parser: per line,
# match a catalogued column against its bound string literal(s) and fail on any
# literal absent from the spec catalog. Set membership (``IN (...)`` / ``= ANY
# (...)``) is single-line only — the forms the migrations actually use.

_LINT_CATALOG: dict[str, frozenset[str]] = {"metric_name": METRIC_NAMES, **ENUM_VALUES}
_STR_LIT = re.compile(r"'([^']*)'")


class LiteralViolation(NamedTuple):
    path: Path
    line: int
    column: str
    literal: str


def _scan_line(col: str, line: str) -> Iterator[str]:
    """Literals bound to ``col`` on one line, across ``=``/``IN``/``ANY`` (#168 forms)."""
    for m in re.finditer(rf"\b{col}\b\s*=\s*'([^']*)'", line):
        yield m.group(1)
    for m in re.finditer(rf"\b{col}\b\s*(?:=\s*ANY\s*|\bIN\s*)\(([^)]*)\)", line, re.IGNORECASE):
        yield from _STR_LIT.findall(m.group(1))


def lint_mart_literals(migrations_dir: Path = _MIGRATIONS_DIR) -> list[LiteralViolation]:
    """Flag metric-name/enum literals in migration SQL absent from the catalog."""
    violations: list[LiteralViolation] = []
    for path in sorted(migrations_dir.glob("*.sql")):
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for col, allowed in _LINT_CATALOG.items():
                for lit in _scan_line(col, line):
                    if lit not in allowed:
                        violations.append(LiteralViolation(path, lineno, col, lit))
    return violations


# --- CLI ----------------------------------------------------------------------


def _run_check(database_url: str | None) -> int:
    rc = 0
    lint = lint_mart_literals()
    if lint:
        rc = 1
        report = "\n".join(
            f"  {v.path.name}:{v.line} {v.column} = '{v.literal}' not in spec catalog" for v in lint
        )
        print("spec_sync: mart-literal lint:\n" + report, file=sys.stderr)
    with _ephemeral_pg.connection(database_url, _CONTAINER, _MIGRATIONS_DIR) as conn:
        delta = compute_delta(conn)
    if not delta.empty():
        rc = 1
        print("spec_sync: spec <-> migrations delta:\n" + delta.report(), file=sys.stderr)
    if rc == 0:
        print("spec_sync: spec and migrations converge; mart literals catalogued.")
    return rc


def _run_author(name: str, *, allow_destructive: bool) -> int:
    with _ephemeral_pg.ephemeral_db(_CONTAINER, _MIGRATIONS_DIR) as conn:
        delta = compute_delta(conn)
    if delta.empty():
        print("spec_sync: nothing to do — spec already matches migrations.")
        return 0
    sql = generate_migration(name, delta, allow_destructive=allow_destructive)
    stamp = datetime.now(UTC).strftime("%Y%m%d%H%M%S")
    dest = _MIGRATIONS_DIR / f"{stamp}_{name}.sql"
    dest.write_text(sql, encoding="utf-8")
    print(f"spec_sync: wrote {dest.relative_to(_REPO_ROOT)}")
    # Re-apply from zero (incl. the new file) and regenerate schema.sql.
    subprocess.run([str(_REPO_ROOT / "scripts" / "dev-migrate.sh")], check=True)
    with _ephemeral_pg.ephemeral_db(_CONTAINER, _MIGRATIONS_DIR) as conn:
        if not compute_delta(conn).empty():
            print("spec_sync: generated migration did not close the delta.", file=sys.stderr)
            return 1
    print("spec_sync: migration applied; delta closed.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="spec_sync", description=__doc__)
    parser.add_argument("--check", action="store_true", help="gate mode (default)")
    parser.add_argument("--name", help="author mode: slug for the generated migration")
    parser.add_argument("--database-url", help="already-migrated DB for --check")
    parser.add_argument("--allow-destructive", action="store_true", help="permit DROP COLUMN")
    args = parser.parse_args(argv)

    if args.name:
        return _run_author(args.name, allow_destructive=args.allow_destructive)
    return _run_check(args.database_url or os.environ.get("DATABASE_URL"))


if __name__ == "__main__":
    raise SystemExit(main())
