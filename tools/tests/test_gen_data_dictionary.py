from tools.gen_data_dictionary import (
    ColumnStat,
    SignalCount,
    TableProfile,
    _fold_descriptions,
    render,
)


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


def test_fold_qualifies_a_polysemous_column_by_event_family():
    # `trigger` is promoted under two event families with different meanings (#368);
    # collapsing to one of them presented a minority meaning as the whole truth.
    folded = _fold_descriptions(
        [
            ("trigger", "permission_mode_changed", "Mode-change trigger.", ""),
            ("trigger", "compaction", "Compaction trigger (auto/manual).", ""),
        ]
    )
    assert folded["trigger"] == (
        "compaction: Compaction trigger (auto/manual). "
        "/ permission_mode_changed: Mode-change trigger.",
        "",
    )


def test_fold_leaves_a_single_meaning_bare_however_many_families_carry_it():
    # The overwhelming majority of promoted columns are in this case; qualifying them
    # would churn every row of the committed dictionary for no added truth.
    folded = _fold_descriptions(
        [
            ("session_id", "*", "Session identifier.", "join key"),
            ("session_id", "api_request", "Session identifier.", "join key"),
            ("model", "api_request", "Model slug.", ""),
        ]
    )
    assert folded["session_id"] == ("Session identifier.", "join key")
    assert folded["model"] == ("Model slug.", "")


def test_fold_groups_families_that_share_a_meaning_inside_a_polysemous_column():
    folded = _fold_descriptions(
        [
            ("duration_ms", "tool_result", "Tool execution duration.", ""),
            ("duration_ms", "api_request", "Request duration.", ""),
            ("duration_ms", "api_error", "Request duration.", ""),
        ]
    )
    assert folded["duration_ms"] == (
        "api_error, api_request: Request duration. / tool_result: Tool execution duration.",
        "",
    )


def test_fold_treats_description_and_useful_for_independently():
    folded = _fold_descriptions(
        [
            ("trigger", "compaction", "Trigger.", "context budgeting"),
            ("trigger", "permission_mode_changed", "Trigger.", "policy audit"),
        ]
    )
    # one meaning, two audiences: the description stays bare, `useful for` qualifies
    assert folded["trigger"] == (
        "Trigger.",
        "compaction: context budgeting / permission_mode_changed: policy audit",
    )


def test_fold_never_emits_a_prefix_with_nothing_after_it():
    # An undescribed family is a registry gap, not a competing meaning — it must not
    # produce a dangling `family: ` in the cell.
    folded = _fold_descriptions(
        [
            ("effort", "api_request", "Reasoning-effort level.", ""),
            ("effort", "compaction", "", ""),
            ("blank", "api_request", "", ""),
        ]
    )
    assert folded["effort"] == ("Reasoning-effort level.", "")
    assert folded["blank"] == ("", "")


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
