from tools.gen_data_dictionary import (
    ColumnStat,
    RegistryRow,
    SignalCount,
    TableProfile,
    _fold_descriptions,
    render,
)


def _row(
    column_name: str,
    signal: str,
    signal_name: str,
    attr_path: str,
    description: str,
    useful_for: str = "",
) -> RegistryRow:
    return RegistryRow(column_name, signal, signal_name, attr_path, description, useful_for)


def test_fold_qualifies_a_polysemous_column_by_signal_name():
    # `trigger` is promoted under two signal names with different meanings (#368);
    # collapsing to one of them presented a minority meaning as the whole truth.
    folded = _fold_descriptions(
        [
            _row("trigger", "events", "permission_mode_changed", "trigger", "Mode-change trigger."),
            _row("trigger", "events", "compaction", "trigger", "Compaction trigger (auto/manual)."),
        ]
    )
    assert folded["trigger"] == (
        "compaction: Compaction trigger (auto/manual). "
        "/ permission_mode_changed: Mode-change trigger.",
        "",
    )


def test_fold_leaves_a_single_meaning_bare_however_many_rows_carry_it():
    # The overwhelming majority of promoted columns are in this case; qualifying them
    # would churn every row of the committed dictionary for no added truth.
    folded = _fold_descriptions(
        [
            _row("session_id", "resource", "*", "session.id", "Session identifier.", "join key"),
            _row("session_id", "events", "*", "session.id", "Session identifier.", "join key"),
            _row("model", "events", "api_request", "model", "Model slug."),
        ]
    )
    assert folded["session_id"] == ("Session identifier.", "join key")
    assert folded["model"] == ("Model slug.", "")


def test_fold_groups_signal_names_that_share_a_meaning_inside_a_polysemous_column():
    folded = _fold_descriptions(
        [
            _row("duration_ms", "events", "tool_result", "duration_ms", "Tool execution duration."),
            _row("duration_ms", "events", "api_request", "duration_ms", "Request duration."),
            _row("duration_ms", "events", "api_error", "duration_ms", "Request duration."),
        ]
    )
    assert folded["duration_ms"] == (
        "api_error, api_request: Request duration. / tool_result: Tool execution duration.",
        "",
    )


def test_fold_falls_back_to_attr_path_when_the_signal_name_cannot_discriminate():
    # Two source attributes promoted into one column: `signal_name` is `*` on both rows,
    # so a signal-name prefix would render a useless `*: ... / *: ...` (#368).
    folded = _fold_descriptions(
        [
            _row("user_account_id", "events", "*", "user.account_id", "Anthropic tagged id."),
            _row("user_account_id", "metrics", "*", "user.account_uuid", "Anthropic account UUID."),
            _row("user_account_id", "metrics", "*", "user.account_id", "Anthropic tagged id."),
        ]
    )
    assert folded["user_account_id"] == (
        "user.account_id: Anthropic tagged id. / user.account_uuid: Anthropic account UUID.",
        "",
    )


def test_fold_falls_back_to_signal_when_neither_signal_name_nor_attr_path_discriminates():
    # Same attr path, same `*` signal name, drifting wording across signals — only the signal
    # itself tells the two texts apart.
    folded = _fold_descriptions(
        [
            _row("user_email", "events", "*", "user.email", "Developer identity (normalized)."),
            _row("user_email", "metrics", "*", "user.email", "Developer identity (lowercase)."),
            _row("user_email", "resource", "*", "user.email", "Developer identity (lowercase)."),
        ]
    )
    assert folded["user_email"] == (
        "events: Developer identity (normalized). "
        "/ metrics, resource: Developer identity (lowercase).",
        "",
    )


def test_fold_treats_description_and_useful_for_independently():
    folded = _fold_descriptions(
        [
            _row("trigger", "events", "compaction", "trigger", "Trigger.", "context budgeting"),
            _row("trigger", "events", "permission_mode_changed", "trigger", "Trigger.", "audit"),
        ]
    )
    # one meaning, two audiences: the description stays bare, `useful for` qualifies
    assert folded["trigger"] == (
        "Trigger.",
        "compaction: context budgeting / permission_mode_changed: audit",
    )


def test_fold_never_emits_a_prefix_with_nothing_after_it():
    # An undescribed row is a registry gap, not a competing meaning — it must not
    # produce a dangling `label: ` in the cell.
    folded = _fold_descriptions(
        [
            _row("effort", "events", "api_request", "effort", "Reasoning-effort level."),
            _row("effort", "events", "compaction", "effort", ""),
            _row("blank", "events", "api_request", "blank", ""),
        ]
    )
    assert folded["effort"] == ("Reasoning-effort level.", "")
    assert folded["blank"] == ("", "")


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
        [("resource", "*", "host.name", "kept", "Hostname.", "", "nature", None)],
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
    assert "| resource | `*` | `host.name` | kept | nature | Hostname. |  |" in md
    # exactly one trailing newline — main() writes this verbatim, and a trailing
    # blank line would be stripped again by the end-of-file-fixer on every commit
    assert md.endswith("|\n") and not md.endswith("\n\n")


def test_kept_basis_column_renders_the_partner_and_omits_it_for_denied():
    # This column is where a kept row's reasoning becomes published rather than living
    # only in docs/research/promotion-candidate-profile.md (#366).
    md = render(
        [_profile()],
        [
            ("resource", "*", "os.version", "kept", "OS version.", "", "collinear", "os.type"),
            ("events", "*", "error", "denied", "Error text.", "", None, None),
        ],
        database="cc_otel",
        generated="2026-07-30",
    )
    assert "| resource | `*` | `os.version` | kept | collinear(os.type) |" in md
    assert "| events | `*` | `error` | denied | — |" in md
