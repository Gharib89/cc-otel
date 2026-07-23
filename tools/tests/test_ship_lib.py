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


def test_emit_builds_a_json_object_with_raw_and_quoted_values():
    out = _run('ship_emit actionable true reason "$(ship_qstr "open, no PR")" assignees "[]"')
    assert out.strip() == '{"actionable":true,"reason":"open, no PR","assignees":[]}'


def test_qstr_escapes_quotes_and_backslashes():
    assert _run(r'ship_qstr "a\"b\\c"').strip() == r'"a\"b\\c"'
