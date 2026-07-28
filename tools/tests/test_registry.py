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


def test_resource_attr_resolves_under_a_signal_path():
    # The sink merges resource attrs into each signal's flat namespace, so a
    # resource attribute seen at events/api_request/os.type is the same byte the
    # parser already reads — not a second fact needing a second verdict.
    reg = Registry(ROWS)
    assert reg.status_of("events", "api_request", "os.type") == "kept"
    assert reg.status_of("metrics", "claude_code.token.usage", "os.type") == "kept"


def test_resource_fallback_leaves_unknown_keys_unclassified():
    reg = Registry(ROWS)
    assert reg.status_of("events", "api_request", "brand.new") is None
    assert reg.status_of("resource", "*", "brand.new") is None


def test_resource_fallback_keeps_per_name_resurfacing():
    # The fallback narrows the *signal* dimension only. An attr registered under
    # specific names still resurfaces under a new one — compaction.trigger is live
    # proof that meaning genuinely differs per event family.
    reg = Registry(ROWS)
    assert reg.status_of("metrics", "claude_code.token.usage", "type") == "promoted"
    assert reg.status_of("metrics", "claude_code.session.count", "type") is None


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
