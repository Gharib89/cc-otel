from tools._registry import Registry

ROWS = [
    ("metrics", "*", "model", "promoted"),
    ("metrics", "claude_code.token.usage", "type", "promoted"),
    ("resource", "*", "os.type", "kept"),
    ("events", "*", "file_path", "denied"),
]


def test_status_of_matches_exact_name_then_wildcard():
    reg = Registry(ROWS)
    # '*' row matches any name
    assert reg.status_of("metrics", "claude_code.session.count", "model") == "promoted"
    # per-name row matches only that name
    assert reg.status_of("metrics", "claude_code.token.usage", "type") == "promoted"
    assert reg.status_of("metrics", "some.other.metric", "type") is None
    # unknown key
    assert reg.status_of("metrics", "x", "nope") is None


def test_diff_splits_unclassified_and_denied_leaks():
    reg = Registry(ROWS)
    extracted = {
        ("metrics", "claude_code.token.usage", "model"),  # known via '*'
        ("metrics", "claude_code.token.usage", "new_attr"),  # unclassified
        ("resource", "*", "os.type"),  # known kept
        ("events", "tool_result", "file_path"),  # denied but present -> leak
    }
    diff = reg.diff(extracted)
    assert diff.unclassified == [("metrics", "claude_code.token.usage", "new_attr")]
    assert diff.leaks == [("events", "tool_result", "file_path")]
