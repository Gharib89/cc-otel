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
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import psycopg
from cc_otel_sink.config import load_settings

# (raw table, signal-name column, event-time column, registry signal)
_TABLES = [
    ("metrics", "metric_name", "ts", "metrics"),
    ("events", "event_name", "event_time", "events"),
]


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


def _registry_descriptions(conn: psycopg.Connection, signal: str) -> dict[str, tuple[str, str]]:
    """column_name -> (description, useful_for) for promoted rows of this signal + resource."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT DISTINCT ON (column_name) column_name, "
            "coalesce(description, ''), coalesce(useful_for, '') "
            "FROM meta.column_registry "
            "WHERE status = 'promoted' AND signal IN (%s, 'resource') AND column_name IS NOT NULL "
            "ORDER BY column_name, signal_name, attr_path",
            (signal,),
        )
        return {r[0]: (r[1], r[2]) for r in cur.fetchall()}


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


def _kept_denied(conn: psycopg.Connection) -> list[tuple[str, str, str, str, str, str]]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT signal, signal_name, attr_path, status, "
            "coalesce(description, ''), coalesce(useful_for, '') "
            "FROM meta.column_registry WHERE status IN ('kept', 'denied') "
            "ORDER BY signal, status, signal_name, attr_path"
        )
        return cur.fetchall()


def _pct(v: float | None) -> str:
    return "—" if v is None else f"{v:.1f}%"


def render(
    profiles: list[TableProfile],
    kept_denied: list[tuple[str, str, str, str, str, str]],
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
        "| signal | signal name | attr path | status | description | useful for |",
        "|---|---|---|---|---|---|",
    ]
    out += [
        f"| {sig} | `{name}` | `{path}` | {status} | {desc} | {useful} |"
        for sig, name, path, status, desc, useful in kept_denied
    ]
    out.append("")
    return "\n".join(out)


def build(conn: psycopg.Connection) -> str:
    profiles = [_profile_table(conn, t, n, ts, s) for t, n, ts, s in _TABLES]
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

    if args.out == "-":
        print(markdown)
    else:
        Path(args.out).write_text(markdown + "\n", encoding="utf-8")
        print(f"Wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
