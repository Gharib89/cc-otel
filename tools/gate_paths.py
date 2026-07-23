"""Derive which CI workflows a set of changed files would trigger.

Mirrors GitHub's `pull_request` path-filter semantics (see the filter patterns
cheat sheet) so `scripts/ship/local-gate.sh` can select its local gates from the
workflows themselves instead of a hand-maintained regex per workflow.

    git diff --name-only origin/main | uv run python -m tools.gate_paths
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

import yaml


class UnsupportedFilterError(Exception):
    """A workflow uses a `paths:` feature this helper doesn't model."""


def _glob_to_regex(pattern: str) -> re.Pattern[str]:
    """Translate a GitHub Actions path-filter glob to an anchored regex.

    `**` matches any chars including `/`; `*` matches any chars except `/`;
    `?` matches one char except `/`; everything else is literal. The whole
    path must match (`re.fullmatch`). `**/` is special-cased to an optional
    "zero or more path segments" group so `**/*.py` matches a root-level
    `a.py` as well as `sink/src/a.py` (GitHub's own documented behavior).
    """
    out = []
    i = 0
    while i < len(pattern):
        if pattern[i : i + 3] == "**/":
            out.append("(?:.*/)?")
            i += 3
        elif pattern[i : i + 2] == "**":
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out))


def _matches_any(path: str, patterns: list[str]) -> bool:
    return any(_glob_to_regex(p).fullmatch(path) for p in patterns)


def _pull_request_paths(data: dict[str, Any], workflow_path: Path) -> list[str] | None:
    """Return the `pull_request` trigger's `paths:` list, or None if untriggered.

    `None` means "no pull_request trigger at all" (workflow never runs on a PR).
    An empty-but-present `paths` key (or `pull_request:` with no paths at all)
    means "triggered by any changed file" — represented as `["**"]`.
    """
    # YAML 1.1 gotcha: an unquoted `on:` key parses as the boolean True.
    on = data.get("on", data.get(True))
    if not isinstance(on, dict):
        return None
    if "pull_request" not in on:
        return None
    pr = on["pull_request"]
    if not isinstance(pr, dict):
        return ["**"]  # `pull_request:` (null) — any changed file triggers it
    if "paths-ignore" in pr:
        raise UnsupportedFilterError(f"{workflow_path}: paths-ignore is unsupported")
    paths = pr.get("paths")
    if not paths:
        return ["**"]
    for p in paths:
        if isinstance(p, str) and p.startswith("!"):
            raise UnsupportedFilterError(
                f"{workflow_path}: negated path pattern {p!r} is unsupported"
            )
    return list(paths)


def triggered_workflows(changed_files: list[str], workflows_dir: Path) -> list[str]:
    """Names of workflows a `pull_request` with these changed files would trigger."""
    names: set[str] = set()
    for workflow_path in sorted(workflows_dir.glob("*.yml")):
        try:
            data = yaml.safe_load(workflow_path.read_text())
        except yaml.YAMLError as err:
            raise UnsupportedFilterError(f"{workflow_path}: failed to parse YAML: {err}") from err
        if not isinstance(data, dict):
            continue
        paths = _pull_request_paths(data, workflow_path)
        if paths is None:
            continue
        if any(_matches_any(f, paths) for f in changed_files):
            name = data.get("name") or workflow_path.stem
            names.add(str(name))
    return sorted(names)


def main(argv: list[str] | None = None) -> int:
    # Force LF line endings even on Windows: local-gate.sh (git-bash) does exact
    # line matching (`grep -qxF`) against this output, which a platform-default
    # CRLF translation would silently break.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(newline="\n")
    argv = sys.argv[1:] if argv is None else argv
    workflows_dir = Path(argv[0]) if argv else Path(".github/workflows")
    changed_files = [line.strip() for line in sys.stdin if line.strip()]
    try:
        for name in triggered_workflows(changed_files, workflows_dir):
            print(name)
    except UnsupportedFilterError as err:
        print(f"gate_paths: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
