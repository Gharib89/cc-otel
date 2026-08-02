"""Subprocess tests for scripts/ship/_lib.sh — the shared ship-mechanics helpers (#230).

Invokes bash so the shell functions are tested as the phase scripts actually use
them (source, then call). Skipped where bash is unavailable.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

_LIB_SRC = (Path(__file__).resolve().parents[2] / "scripts" / "ship" / "_lib.sh").read_text(
    encoding="utf-8"
)

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="bash not on PATH")


def _run(snippet: str) -> str:
    # Feed the lib text + snippet on stdin, not as a `bash -c` argument: on
    # Windows the argv boundary mangles the non-ASCII bytes in the lib's comments
    # (and the `bash` on PATH may be git-bash or WSL, which disagree on how a
    # passed cwd / relative source path resolves). A UTF-8 stdin stream sidesteps
    # both — bash reads its script from stdin when given no file argument.
    # Bytes, not text mode: subprocess's universal-newline translation would
    # rewrite every `\n` to `\r\n` on Windows, and bash chokes on the `\r`.
    result = subprocess.run(
        ["bash"],
        input=f"{_LIB_SRC}\n{snippet}\n".encode(),
        capture_output=True,
        check=True,
    )
    return result.stdout.decode()


def test_ship_branch_constructs_type_slug_issue():
    assert _run("ship_branch feat script-skills 135") == "feat/script-skills-135"


def test_branch_suffix_re_matches_only_the_issue_suffix():
    # The constructed branch matches its own issue's suffix regex...
    assert (
        _run(
            "b=$(ship_branch refactor sig-table 230); [[ $b =~ $(ship_branch_suffix_re 230) ]] "
            "&& echo match || echo no"
        ).strip()
        == "match"
    )
    # ...but not a different issue's, and not a numeric prefix (anchored end).
    assert (
        _run(
            "b=$(ship_branch refactor sig-table 230); [[ $b =~ $(ship_branch_suffix_re 23) ]] "
            "&& echo match || echo no"
        ).strip()
        == "no"
    )


def test_env_inventory_lists_the_three_gitignored_files():
    assert _run('printf "%s\\n" "${SHIP_ENV_FILES[@]}"').split() == [
        ".env",
        ".env.interim",
        ".env.prod",
    ]


def test_emit_quotes_string_values_by_default():
    # New contract (#269): a bare value is quoted/escaped as a JSON string —
    # callers no longer wrap it in ship_qstr.
    assert _run('ship_emit reason "open, no PR"').strip() == '{"reason":"open, no PR"}'


def test_emit_at_sigil_marks_raw_json():
    # An @-prefixed value is emitted verbatim (sigil stripped): bools, arrays, numbers.
    assert _run("ship_emit actionable @true").strip() == '{"actionable":true}'
    assert _run('ship_emit assignees @"[]"').strip() == '{"assignees":[]}'


def test_emit_mixes_quoted_and_raw():
    out = _run('ship_emit actionable @true reason "open, no PR" assignees @"[]"')
    assert out.strip() == '{"actionable":true,"reason":"open, no PR","assignees":[]}'


def test_emit_forgotten_sigil_yields_valid_json_stringified_bool():
    # The whole point of inverting the default: a forgotten sigil now emits a
    # stringified bool — valid JSON, benign to the LLM consumer — not invalid JSON.
    assert _run("ship_emit actionable true").strip() == '{"actionable":"true"}'


def test_emit_escapes_special_chars_in_string_values():
    assert _run('ship_emit reason "a\\"b"').strip() == r'{"reason":"a\"b"}'


def test_qstr_escapes_quotes_and_backslashes():
    assert _run(r'ship_qstr "a\"b\\c"').strip() == r'"a\"b\\c"'


def test_qstr_escapes_control_characters():
    # newline / tab / carriage return must become \n \t \r so the JSON stays valid
    assert _run("ship_qstr $'a\\tb\\nc\\rd'").strip() == r'"a\tb\nc\rd"'


# --- Windows PowerShell Pester status (#401) -----------------------------------
# local-gate.sh runs bootstrap:pester under Windows PowerShell 5.1 (the shell
# bootstrap.yml's CI job uses) via winps-pester.ps1, which exits 3 when no Pester 5
# is reachable from 5.1. The mapping below is the load-bearing part: exit 3 must
# never read as `pass`, or "local gate green" silently means less than CI green.


def test_winps_pester_status_maps_success_to_pass():
    assert _run("ship_winps_pester_status 0") == "pass"


def test_winps_pester_status_maps_the_unresolved_sentinel():
    assert _run("ship_winps_pester_status 3") == "unresolved"


@pytest.mark.parametrize("code", ["1", "2", "4", "127"])
def test_winps_pester_status_maps_every_other_code_to_fail(code):
    # A suite failure, a missing script, an unrunnable shell — all fail; only the
    # explicit sentinel earns the deferred-to-ci downgrade.
    assert _run(f"ship_winps_pester_status {code}") == "fail"


# --- secrets regex (SECRET_RE / IGNORE_RE, moved into _lib.sh by #269) --------
# Exercised through grep exactly as local-gate.sh's scanner uses them. The sample
# credentials are assembled from fragments at runtime so no *source* line in this
# file is itself a contiguous secret — local-gate.sh's own scanner reads this file
# during the gate, and a real match here would be a false positive.


def _secret_scan(line: str) -> str:
    # Mirror local-gate.sh's pipe: drop IGNORE_RE lines, then match SECRET_RE (-i).
    # The line rides in as bash's $1 (git-bash on Windows drops inherited env vars),
    # sidestepping any shell-quoting of its embedded quotes.
    snippet = (
        'printf "%s\\n" "$1" '
        '| { grep -vE "$IGNORE_RE" || true; } '
        '| { grep -Ei "$SECRET_RE" || true; }'
    )
    result = subprocess.run(
        ["bash", "-s", "--", line],  # -- so a line starting with `-` isn't read as a flag
        input=f"{_LIB_SRC}\n{snippet}\n".encode(),
        capture_output=True,
        check=True,
    )
    return result.stdout.decode().strip()


@pytest.mark.parametrize(
    "line",
    [
        "postgres://admin:" + "s3cr3tpw@db.example.com:5432/prod",
        "bearer " + "a" * 30,
        "AKIA" + "ABCDEFGHIJKLMNOP",
        "-----BEGIN RSA " + "PRIVATE KEY-----",
        "client_" + "secret=abc123",
        "sig=" + "a" * 35,
    ],
)
def test_secret_re_flags_real_credentials(line):
    assert _secret_scan(line) == line


@pytest.mark.parametrize(
    "line",
    [
        "just a normal log line with no secrets",
        "postgres://postgres:" + "postgres@localhost:5432/test",  # sanctioned via IGNORE_RE
    ],
)
def test_secret_re_ignores_benign_and_sanctioned(line):
    assert _secret_scan(line) == ""
