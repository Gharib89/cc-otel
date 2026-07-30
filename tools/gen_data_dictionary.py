"""Regenerate ``docs/data-dictionary.md`` from Postgres + the column registry.

The registry (``meta.column_registry``) is the backbone: every promoted column is
described and given **live profiling stats** (non-null %, unique %, distinct count) read
from ``raw.metrics`` / ``raw.events``; kept and denied keys — which have no Postgres
column (schema-v2 has no JSONB) — are listed with their registry metadata but no stats.
Their live population is what ``tools.sweep`` is for.

A step in the promotion-PR bundle (docs/agents/column-curation.md): regenerate and commit
so the committed dictionary never drifts from the schema.

    uv run python -m tools.gen_data_dictionary            # -> docs/data-dictionary.md
    uv run python -m tools.gen_data_dictionary --out -    # -> stdout
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import psycopg
from cc_otel_sink.config import load_settings

from .signals import SIGNALS


@dataclass(frozen=True)
class RegistryRow:
    """One promoted ``meta.column_registry`` row, at the registry's own grain."""

    column_name: str
    signal: str
    signal_name: str
    attr_path: str
    description: str
    useful_for: str


@dataclass(frozen=True)
class ColumnStat:
    name: str
    data_type: str
    non_null_pct: float
    unique_pct: float | None  # None when the column is entirely NULL
    distinct: int
    description: str
    useful_for: str


@dataclass(frozen=True)
class SignalCount:
    name: str
    rows: int
    pct: float
    first_seen: str
    last_seen: str


@dataclass(frozen=True)
class TableProfile:
    table: str
    total_rows: int
    signal_counts: list[SignalCount]
    columns: list[ColumnStat]


def _columns(conn: psycopg.Connection, table: str) -> list[tuple[str, str]]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT column_name, data_type FROM information_schema.columns "
            "WHERE table_schema = 'raw' AND table_name = %s ORDER BY ordinal_position",
            (table,),
        )
        return [(r[0], r[1]) for r in cur.fetchall()]


# Narrowest-first: a polysemous column's groups are labelled by the first of these that
# tells them apart. Signal name reads best (`api_error: ...`) but is `*` for every
# resource-shaped attribute, and two source attr paths can share one column — so the
# ladder falls back until the labels discriminate.
_QUALIFIERS: tuple[Callable[[RegistryRow], str], ...] = (
    lambda r: r.signal_name,
    lambda r: r.attr_path,
    lambda r: r.signal,
)


def _full_grain(row: RegistryRow) -> str:
    """The registry's grain is unique by construction, so labelling by the whole of it
    always discriminates — the terminal rung, needed only if all three above collide."""
    return f"{row.signal}/{row.signal_name}/{row.attr_path}"


def _discriminating_qualifier(
    groups: dict[str, list[RegistryRow]],
) -> Callable[[RegistryRow], str]:
    for qualifier in _QUALIFIERS:
        labels = [label for rows in groups.values() for label in {qualifier(r) for r in rows}]
        if len(labels) == len(set(labels)):  # no label shared by two groups
            return qualifier
    return _full_grain


def _qualify(rows: list[RegistryRow], text_of: Callable[[RegistryRow], str]) -> str:
    """Fold one column's registry rows into a single cell for the given text field.

    The registry's grain is ``(signal, signal_name, attr_path)``, so a promoted column can
    carry a different meaning per signal name (`duration_ms`, `trigger`) or per source
    attribute (`user_account_id`). Grouping is by **text**, not by row: rows sharing one
    wording collapse into a single labelled group, which is what stops the cell growing
    once per registry row. A column with one distinct meaning renders bare, exactly as it
    did before #368.
    """
    groups: dict[str, list[RegistryRow]] = {}
    for row in rows:
        if text_of(row):  # an undescribed row is a registry gap, not a rival meaning
            groups.setdefault(text_of(row), []).append(row)
    if len(groups) <= 1:
        return next(iter(groups), "")
    qualifier = _discriminating_qualifier(groups)
    labelled = sorted(
        ((sorted({qualifier(r) for r in group_rows}), body) for body, group_rows in groups.items()),
        key=lambda g: g[0][0],
    )
    return " / ".join(f"{', '.join(labels)}: {body}" for labels, body in labelled)


def _fold_descriptions(rows: list[RegistryRow]) -> dict[str, tuple[str, str]]:
    """Registry rows -> ``column_name -> (description, useful_for)`` cells.

    Pure — the DB round trip lives in ``_registry_descriptions``. The two text fields are
    folded independently: a column can be polysemous in one and not the other.
    """
    per_column: dict[str, list[RegistryRow]] = {}
    for row in rows:
        per_column.setdefault(row.column_name, []).append(row)
    return {
        column: (
            _qualify(column_rows, lambda r: r.description),
            _qualify(column_rows, lambda r: r.useful_for),
        )
        for column, column_rows in per_column.items()
    }


def _registry_descriptions(conn: psycopg.Connection, signal: str) -> dict[str, tuple[str, str]]:
    """column_name -> (description, useful_for) for promoted rows of this signal + resource."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT column_name, signal, signal_name, attr_path, "
            "coalesce(description, ''), coalesce(useful_for, '') "
            "FROM meta.column_registry "
            "WHERE status = 'promoted' AND signal IN (%s, 'resource') AND column_name IS NOT NULL",
            (signal,),
        )
        return _fold_descriptions([RegistryRow(*r) for r in cur.fetchall()])


def _profile_table(
    conn: psycopg.Connection, table: str, name_col: str, ts_col: str, signal: str
) -> TableProfile:
    cols = _columns(conn, table)
    descriptions = _registry_descriptions(conn, signal)

    # One scan for every column's null/distinct counts.
    aggs = ", ".join(
        f'count("{c}") AS nn_{i}, count(DISTINCT "{c}") AS d_{i}' for i, (c, _) in enumerate(cols)
    )
    with conn.cursor() as cur:
        cur.execute(f'SELECT count(*) AS n, {aggs} FROM raw."{table}"')  # noqa: S608 - identifiers from schema introspection
        row = cur.fetchone()
    total = row[0]

    columns: list[ColumnStat] = []
    for i, (name, data_type) in enumerate(cols):
        non_null, distinct = row[1 + 2 * i], row[2 + 2 * i]
        desc, useful = descriptions.get(name, ("", ""))
        columns.append(
            ColumnStat(
                name=name,
                data_type=data_type,
                non_null_pct=100.0 * non_null / total if total else 0.0,
                unique_pct=(100.0 * distinct / non_null) if non_null else None,
                distinct=distinct,
                description=desc,
                useful_for=useful,
            )
        )

    with conn.cursor() as cur:
        cur.execute(
            f'SELECT "{name_col}", count(*), min("{ts_col}")::date, max("{ts_col}")::date '  # noqa: S608
            f'FROM raw."{table}" GROUP BY 1 ORDER BY 2 DESC'
        )
        sig_rows = cur.fetchall()
    signal_counts = [
        SignalCount(
            name=r[0],
            rows=r[1],
            pct=100.0 * r[1] / total if total else 0.0,
            first_seen=str(r[2]) if r[2] else "—",
            last_seen=str(r[3]) if r[3] else "—",
        )
        for r in sig_rows
    ]
    return TableProfile(table=table, total_rows=total, signal_counts=signal_counts, columns=columns)


KeptDeniedRow = tuple[str, str, str, str, str, str, str | None, str | None]


def _kept_denied(conn: psycopg.Connection) -> list[KeptDeniedRow]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT signal, signal_name, attr_path, status, "
            "coalesce(description, ''), coalesce(useful_for, ''), kept_basis, basis_partner "
            "FROM meta.column_registry WHERE status IN ('kept', 'denied') "
            "ORDER BY signal, status, signal_name, attr_path"
        )
        return cur.fetchall()


def _basis(kept_basis: str | None, partner: str | None) -> str:
    """Render a kept basis for the table — ``collinear`` names its partner (#366)."""
    if kept_basis is None:
        return "—"  # a denied row has no basis
    return f"{kept_basis}({partner})" if partner else kept_basis


def _pct(v: float | None) -> str:
    return "—" if v is None else f"{v:.1f}%"


def render(
    profiles: list[TableProfile],
    kept_denied: list[KeptDeniedRow],
    database: str,
    generated: str,
) -> str:
    out: list[str] = [
        "# cc-otel — Data Dictionary",
        "",
        f"> Generated **{generated}** by `tools.gen_data_dictionary` against `{database}`.",
        "> Row counts are a live snapshot; treat them as representative, not exact.",
        "",
        "Descriptions come from `meta.column_registry` (the curated catalogue, #16); profiling",
        "stats are live from `raw.metrics` / `raw.events`. Kept (blob-only) and denied (stripped)",
        "keys have no Postgres column, so they are listed without live stats — use `tools.sweep`",
        "to see what is actually present in the blob reservoir.",
        "",
        "**Regenerate:** `uv run python -m tools.gen_data_dictionary` (commit the result).",
        "",
        "## Tables profiled",
        "",
        "| table | rows |",
        "|---|---:|",
    ]
    out += [f"| `raw.{p.table}` | {p.total_rows:,} |" for p in profiles]
    out.append("")

    for p in profiles:
        out += [f"## `raw.{p.table}`", ""]
        out += [
            "### Row counts by signal name",
            "",
            "| name | rows | % | first seen | last seen |",
            "|---|---:|---:|---|---|",
        ]
        out += [
            f"| `{s.name}` | {s.rows:,} | {s.pct:.1f}% | {s.first_seen} | {s.last_seen} |"
            for s in p.signal_counts
        ]
        out += [
            "",
            "### Promoted columns",
            "",
            "| column | type | non-null % | unique % | distinct | description | useful for |",
            "|---|---|---:|---:|---:|---|---|",
        ]
        out += [
            f"| `{c.name}` | {c.data_type} | {c.non_null_pct:.1f}% | {_pct(c.unique_pct)} | "
            f"{c.distinct:,} | {c.description} | {c.useful_for} |"
            for c in p.columns
        ]
        out.append("")

    out += [
        "## Kept & denied attributes (not in Postgres)",
        "",
        "`kept` = blob reservoir only; `denied` = stripped by the sink wherever seen.",
        "",
        "**basis** is why a key is `kept` rather than promoted (#366): `nature` (identity or",
        "unbounded cardinality), `constant`, `collinear(partner)`, `thin`, or `redundant`. Only",
        "`nature` is unfalsifiable — `uv run python -m tools.basis_drift` re-checks the rest",
        "against a recent window.",
        "",
        "| signal | signal name | attr path | status | basis | description | useful for |",
        "|---|---|---|---|---|---|---|",
    ]
    out += [
        f"| {sig} | `{name}` | `{path}` | {status} | {_basis(basis, partner)} | "
        f"{desc} | {useful} |"
        for sig, name, path, status, desc, useful, basis, partner in kept_denied
    ]
    out.append("")
    return "\n".join(out)


def build(conn: psycopg.Connection) -> str:
    profiles = [
        _profile_table(conn, s.raw_table, s.name_col, s.time_col, s.registry_name) for s in SIGNALS
    ]
    with conn.cursor() as cur:
        cur.execute("SELECT current_database()")
        database = cur.fetchone()[0]
    generated = datetime.now(UTC).strftime("%Y-%m-%d")
    return render(profiles, _kept_denied(conn), database, generated)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--out", default="docs/data-dictionary.md", help="output path, or - for stdout")
    args = p.parse_args(argv)

    settings = load_settings()
    with psycopg.connect(settings.database_url) as conn:
        markdown = build(conn)

    # render() already ends with a newline; a second one is a trailing blank line,
    # which the repo's end-of-file-fixer strips back out on commit. Both branches
    # emit the same bytes so `--out -` can be diffed against the committed file.
    if args.out == "-":
        print(markdown, end="")
    else:
        Path(args.out).write_text(markdown, encoding="utf-8")
        print(f"Wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
