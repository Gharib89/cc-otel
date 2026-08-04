import subprocess
import sys
from pathlib import Path

import pytest

from tools.gate_paths import UnsupportedFilterError, main, triggered_workflows

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"


def _write_workflow(tmp_path: Path, name: str, content: str) -> Path:
    path = tmp_path / name
    path.write_text(content)
    return path


# --- glob semantics -----------------------------------------------------------


def test_double_star_matches_any_depth(tmp_path: Path):
    _write_workflow(
        tmp_path,
        "w.yml",
        "name: w\non:\n  pull_request:\n    paths:\n      - '**/*.py'\n",
    )
    assert triggered_workflows(["a.py"], tmp_path) == ["w"]
    assert triggered_workflows(["sink/src/a.py"], tmp_path) == ["w"]


def test_double_star_dir_prefix_scopes_extension(tmp_path: Path):
    _write_workflow(
        tmp_path,
        "w.yml",
        "name: w\non:\n  pull_request:\n    paths:\n      - 'db/**/*.sql'\n",
    )
    assert triggered_workflows(["db/migrations/x.sql"], tmp_path) == ["w"]
    assert triggered_workflows(["db/x.py"], tmp_path) == []
    assert triggered_workflows(["dbx/y.sql"], tmp_path) == []


def test_literal_pattern_matches_exactly(tmp_path: Path):
    _write_workflow(
        tmp_path,
        "w.yml",
        "name: w\non:\n  pull_request:\n    paths:\n      - '.sqlfluff'\n",
    )
    assert triggered_workflows([".sqlfluff"], tmp_path) == ["w"]
    assert triggered_workflows(["x.sqlfluff"], tmp_path) == []
    assert triggered_workflows(["a/.sqlfluff"], tmp_path) == []


def test_single_star_does_not_cross_slash(tmp_path: Path):
    _write_workflow(
        tmp_path,
        "w.yml",
        "name: w\non:\n  pull_request:\n    paths:\n      - 'installer/*.ps1'\n",
    )
    assert triggered_workflows(["installer/install.ps1"], tmp_path) == ["w"]
    assert triggered_workflows(["installer/sub/install.ps1"], tmp_path) == []


def test_question_mark_matches_single_non_slash_char(tmp_path: Path):
    _write_workflow(
        tmp_path,
        "w.yml",
        "name: w\non:\n  pull_request:\n    paths:\n      - 'a?.txt'\n",
    )
    assert triggered_workflows(["ax.txt"], tmp_path) == ["w"]
    assert triggered_workflows(["a/.txt"], tmp_path) == []
    assert triggered_workflows(["a.txt"], tmp_path) == []


def test_negated_pattern_raises(tmp_path: Path):
    _write_workflow(
        tmp_path,
        "w.yml",
        "name: w\non:\n  pull_request:\n    paths:\n      - '**'\n      - '!README.md'\n",
    )
    with pytest.raises(UnsupportedFilterError):
        triggered_workflows(["README.md"], tmp_path)


def test_scalar_paths_raises(tmp_path: Path):
    _write_workflow(
        tmp_path,
        "w.yml",
        "name: w\non:\n  pull_request:\n    paths: '**/*.py'\n",
    )
    with pytest.raises(UnsupportedFilterError):
        triggered_workflows(["a.py"], tmp_path)


def test_paths_ignore_raises(tmp_path: Path):
    _write_workflow(
        tmp_path,
        "w.yml",
        "name: w\non:\n  pull_request:\n    paths-ignore:\n      - 'README.md'\n",
    )
    with pytest.raises(UnsupportedFilterError):
        triggered_workflows(["a.py"], tmp_path)


# --- on: -> True pyyaml gotcha -------------------------------------------------


def test_unquoted_on_key_parses_correctly(tmp_path: Path):
    # pyyaml (safe_load, YAML 1.1) parses the unquoted `on:` key as boolean True;
    # gate_paths must look it up via data.get("on", data.get(True)).
    _write_workflow(
        tmp_path,
        "w.yml",
        "name: w\non:\n  pull_request:\n    paths:\n      - 'x/**'\n",
    )
    assert triggered_workflows(["x/y.txt"], tmp_path) == ["w"]


# --- trigger presence / absence ------------------------------------------------


def test_pull_request_with_no_paths_always_triggers(tmp_path: Path):
    _write_workflow(tmp_path, "w.yml", "name: w\non:\n  pull_request:\n")
    assert triggered_workflows(["anything.txt"], tmp_path) == ["w"]
    assert triggered_workflows([], tmp_path) == []


def test_workflow_without_pull_request_never_triggers(tmp_path: Path):
    _write_workflow(
        tmp_path,
        "w.yml",
        "name: w\non:\n  workflow_dispatch:\n",
    )
    assert triggered_workflows(["anything.txt"], tmp_path) == []


def test_name_falls_back_to_file_stem(tmp_path: Path):
    _write_workflow(
        tmp_path,
        "my-workflow.yml",
        "on:\n  pull_request:\n    paths:\n      - '**'\n",
    )
    assert triggered_workflows(["a.txt"], tmp_path) == ["my-workflow"]


# --- real fixture: one assertion per actual repo workflow file ----------------


def test_real_workflows_python_and_integration_and_docker():
    assert triggered_workflows(["sink/src/cc_otel_sink/app.py"], WORKFLOWS_DIR) == [
        "docker",
        "integration",
        "python",
    ]


def test_real_workflows_db_migration():
    assert triggered_workflows(["db/migrations/x.sql"], WORKFLOWS_DIR) == [
        "integration",
        "python",
    ]


def test_real_workflows_pyproject():
    assert triggered_workflows(["pyproject.toml"], WORKFLOWS_DIR) == [
        "integration",
        "python",
    ]


def test_real_workflows_iac():
    assert triggered_workflows(["iac/main.bicep"], WORKFLOWS_DIR) == ["iac"]
    assert triggered_workflows(["ps-rule.yaml"], WORKFLOWS_DIR) == ["iac"]


def test_real_workflows_installer():
    assert triggered_workflows(["installer/install.ps1"], WORKFLOWS_DIR) == ["installer"]


def test_real_workflows_bootstrap():
    assert triggered_workflows(["bootstrap/bootstrap.ps1"], WORKFLOWS_DIR) == ["bootstrap"]


def test_real_workflows_powerbi():
    assert triggered_workflows(["powerbi/report/x.json"], WORKFLOWS_DIR) == ["ci-powerbi"]
    assert triggered_workflows([".github/powerbi/validate.ps1"], WORKFLOWS_DIR) == ["ci-powerbi"]


def test_real_workflows_collector():
    assert triggered_workflows(["collector/config.yaml"], WORKFLOWS_DIR) == [
        "docker",
        "integration",
    ]


def test_real_workflows_readme_triggers_nothing():
    assert triggered_workflows(["README.md"], WORKFLOWS_DIR) == []


def test_real_workflows_manual_and_scheduled_never_appear():
    # These have no `pull_request` trigger at all, so no diff can select them
    # and local-gate.sh carries them in EXCLUDED rather than as gate groups.
    all_touched = [
        "sink/src/cc_otel_sink/app.py",
        "db/migrations/x.sql",
        "pyproject.toml",
        "iac/main.bicep",
        "ps-rule.yaml",
        "installer/install.ps1",
        "bootstrap/bootstrap.ps1",
        "powerbi/report/x.json",
        ".github/powerbi/validate.ps1",
        "collector/config.yaml",
        ".github/workflows/env-schema-status.yml",
        "README.md",
    ]
    triggered = triggered_workflows(all_touched, WORKFLOWS_DIR)
    assert "deploy" not in triggered
    assert "publish-images" not in triggered
    assert "env-schema-status" not in triggered


# --- CLI entry point ------------------------------------------------------------


def test_cli_reads_stdin_and_prints_sorted_deduped_names():
    result = subprocess.run(
        [sys.executable, "-m", "tools.gate_paths"],
        input="pyproject.toml\ndb/migrations/x.sql\n",
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
        check=True,
    )
    assert result.stdout.splitlines() == ["integration", "python"]


def test_cli_nonzero_exit_on_unsupported_filter(tmp_path: Path):
    _write_workflow(
        tmp_path,
        "w.yml",
        "name: w\non:\n  pull_request:\n    paths-ignore:\n      - 'README.md'\n",
    )
    result = subprocess.run(
        [sys.executable, "-m", "tools.gate_paths", str(tmp_path)],
        input="a.py\n",
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    assert result.returncode != 0
    assert "paths-ignore" in result.stderr


def test_main_accepts_argv_directly(tmp_path: Path, capsys: pytest.CaptureFixture[str]):
    _write_workflow(tmp_path, "w.yml", "name: w\non:\n  pull_request:\n")
    import io

    old_stdin = sys.stdin
    sys.stdin = io.StringIO("a.txt\n")
    try:
        rc = main([str(tmp_path)])
    finally:
        sys.stdin = old_stdin
    assert rc == 0
    assert capsys.readouterr().out == "w\n"
