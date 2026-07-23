"""Unit coverage for the pure logic in `scripts/sync-skills.py`.

The script lives under `scripts/` (not the importable `tools` package) and its
filename is hyphenated, so it is loaded by path via importlib rather than
imported. Only the pure, filesystem-scoped helpers are exercised here: ref
extraction, the transitive closure, and the frontmatter strip (including the
documented body-vs-frontmatter hazard).
"""

import importlib.util
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
_SPEC = importlib.util.spec_from_file_location(
    "sync_skills", REPO_ROOT / "scripts" / "sync-skills.py"
)
assert _SPEC and _SPEC.loader
sync_skills = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(sync_skills)


def _skill(root: Path, name: str, *md: tuple[str, str]) -> Path:
    """Create a skill dir under `root` with the given (relative-path, text) md files."""
    skill_dir = root / name
    skill_dir.mkdir(parents=True, exist_ok=True)
    for rel, text in md:
        path = skill_dir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return skill_dir


# --- find_refs: regex ref extraction ------------------------------------------


def test_find_refs_backticked_slash_and_bare(tmp_path: Path):
    d = _skill(tmp_path, "a", ("SKILL.md", "composes `/tdd` and `code-review` here"))
    assert sync_skills.find_refs(d, {"tdd", "code-review"}) == {"tdd", "code-review"}


def test_find_refs_plain_slash_command(tmp_path: Path):
    d = _skill(tmp_path, "a", ("SKILL.md", "run /diagnose when stuck"))
    assert sync_skills.find_refs(d, {"diagnose"}) == {"diagnose"}


def test_find_refs_only_tokens_in_universe_survive(tmp_path: Path):
    # `/not-a-skill` is a false positive (URL-ish); it is not in the universe.
    d = _skill(tmp_path, "a", ("SKILL.md", "see `/tdd` and /not-a-skill/path"))
    assert sync_skills.find_refs(d, {"tdd"}) == {"tdd"}


def test_find_refs_scans_all_markdown_files(tmp_path: Path):
    d = _skill(
        tmp_path,
        "a",
        ("SKILL.md", "top uses `/tdd`"),
        ("reference/deep.md", "nested uses `/qa`"),
    )
    assert sync_skills.find_refs(d, {"tdd", "qa"}) == {"tdd", "qa"}


def test_find_refs_empty_when_no_matches(tmp_path: Path):
    d = _skill(tmp_path, "a", ("SKILL.md", "prose with no references at all"))
    assert sync_skills.find_refs(d, {"tdd"}) == set()


# --- resolve_closure: transitive dependency pull ------------------------------


def test_resolve_closure_transitive(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    # Names are >=2 chars: `_REF` requires `[a-z][a-z0-9-]+`, so single letters
    # never match (real skill slugs are multi-char).
    _skill(tmp_path, "alpha", ("SKILL.md", "uses `/beta`"))
    _skill(tmp_path, "beta", ("SKILL.md", "uses `/gamma`"))
    _skill(tmp_path, "gamma", ("SKILL.md", "leaf"))
    monkeypatch.setattr(sync_skills, "SRC", tmp_path)
    universe = {"alpha", "beta", "gamma"}

    wanted, auto = sync_skills.resolve_closure({"alpha": True}, universe)

    assert set(wanted) == {"alpha", "beta", "gamma"}
    assert auto == {"beta", "gamma"}
    # Seed keeps its forced flag; auto-added deps default to upstream (False).
    assert wanted["alpha"] is True
    assert wanted["beta"] is False
    assert wanted["gamma"] is False


def test_resolve_closure_skips_project_native_and_excluded(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    # `a` references a project-native skill and an excluded one — neither is pulled.
    native = next(iter(sync_skills.PROJECT_NATIVE))
    excluded = next(iter(sync_skills.EXCLUDE))
    _skill(tmp_path, "a", ("SKILL.md", f"uses `/{native}` and `/{excluded}`"))
    _skill(tmp_path, native, ("SKILL.md", "native"))
    _skill(tmp_path, excluded, ("SKILL.md", "excluded"))
    monkeypatch.setattr(sync_skills, "SRC", tmp_path)
    universe = {"a", native, excluded}

    wanted, auto = sync_skills.resolve_closure({"a": False}, universe)

    assert set(wanted) == {"a"}
    assert auto == set()


def test_resolve_closure_missing_source_dir_is_skipped(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    # A seed name with no source dir must not raise; closure just yields the seed.
    monkeypatch.setattr(sync_skills, "SRC", tmp_path)
    wanted, auto = sync_skills.resolve_closure({"ghost": True}, {"ghost"})
    assert set(wanted) == {"ghost"}
    assert auto == set()


# --- strip_model_invocation_flag: frontmatter strip + body hazard -------------


def test_strip_removes_flag_from_frontmatter(tmp_path: Path):
    md = tmp_path / "SKILL.md"
    md.write_text("---\nname: x\ndisable-model-invocation: true\n---\nbody\n", encoding="utf-8")
    assert sync_skills.strip_model_invocation_flag(md) is True
    assert "disable-model-invocation" not in md.read_text(encoding="utf-8")
    assert "name: x" in md.read_text(encoding="utf-8")


def test_strip_leaves_body_occurrence_untouched(tmp_path: Path):
    """The hazard: the flag string in the BODY must never be stripped."""
    md = tmp_path / "SKILL.md"
    md.write_text(
        "---\nname: x\n---\nprose mentioning disable-model-invocation: true literally\n",
        encoding="utf-8",
    )
    # No frontmatter occurrence, so nothing is removed and the body survives.
    assert sync_skills.strip_model_invocation_flag(md) is False
    assert "disable-model-invocation: true literally" in md.read_text(encoding="utf-8")


def test_strip_only_frontmatter_when_flag_in_both(tmp_path: Path):
    """Flag in frontmatter AND body: strip frontmatter line, keep the body line."""
    md = tmp_path / "SKILL.md"
    md.write_text(
        "---\nname: x\ndisable-model-invocation: true\n---\n"
        "body says disable-model-invocation: true too\n",
        encoding="utf-8",
    )
    assert sync_skills.strip_model_invocation_flag(md) is True
    text = md.read_text(encoding="utf-8")
    assert "name: x" in text
    assert "body says disable-model-invocation: true too" in text
    # The frontmatter line is gone; only the body occurrence remains.
    assert text.count("disable-model-invocation") == 1


def test_strip_no_frontmatter_returns_false(tmp_path: Path):
    md = tmp_path / "SKILL.md"
    md.write_text("no frontmatter here\ndisable-model-invocation: true\n", encoding="utf-8")
    assert sync_skills.strip_model_invocation_flag(md) is False


def test_strip_unterminated_frontmatter_returns_false(tmp_path: Path):
    md = tmp_path / "SKILL.md"
    md.write_text("---\nname: x\ndisable-model-invocation: true\n", encoding="utf-8")
    assert sync_skills.strip_model_invocation_flag(md) is False


def test_strip_flag_absent_returns_false(tmp_path: Path):
    md = tmp_path / "SKILL.md"
    original = "---\nname: x\n---\nbody\n"
    md.write_text(original, encoding="utf-8")
    assert sync_skills.strip_model_invocation_flag(md) is False
    assert md.read_text(encoding="utf-8") == original


def test_strip_missing_file_returns_false(tmp_path: Path):
    assert sync_skills.strip_model_invocation_flag(tmp_path / "nope.md") is False
