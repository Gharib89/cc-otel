from tools.gen_data_dictionary import ColumnStat, SignalCount, TableProfile, render


def _profile() -> TableProfile:
    return TableProfile(
        table="metrics",
        total_rows=100,
        signal_counts=[
            SignalCount("claude_code.token.usage", 60, 60.0, "2026-07-01", "2026-07-16"),
        ],
        columns=[
            ColumnStat(
                "metric_name", "text", 100.0, 5.0, 5, "OTel instrument name.", "signal routing"
            ),
            ColumnStat("effort", "text", 0.0, None, 0, "Reasoning-effort level.", ""),
        ],
    )


def test_render_has_sections_and_column_row():
    md = render(
        [_profile()],
        [("resource", "*", "host.name", "kept", "Hostname.", "")],
        database="cc_otel",
        generated="2026-07-16",
    )
    assert "# cc-otel — Data Dictionary" in md
    assert "## `raw.metrics`" in md
    assert "### Row counts by signal name" in md
    # promoted column carries its live stats + registry description
    assert (
        "| `metric_name` | text | 100.0% | 5.0% | 5 | OTel instrument name. | signal routing |"
        in md
    )
    # an all-NULL column renders unique % as em dash
    assert "| `effort` | text | 0.0% | — | 0 |" in md
    # kept/denied section lists the blob-only key
    assert "## Kept & denied attributes (not in Postgres)" in md
    assert "| resource | `*` | `host.name` | kept | Hostname. |  |" in md
    # exactly one trailing newline — main() writes this verbatim, and a trailing
    # blank line would be stripped again by the end-of-file-fixer on every commit
    assert md.endswith("|\n") and not md.endswith("\n\n")
