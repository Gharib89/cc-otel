"""Unit coverage for analysis._common's env loader.

The payload-reading and aggregation coverage moved to ``tools/tests/test_payload.py``
alongside the code (#366); ``_common`` re-exports those names, so the notebooks' imports
are unchanged and the re-export itself is asserted here.
"""

from __future__ import annotations

import os

from analysis import _common


def test_reexports_the_lifted_aggregation() -> None:
    # The notebooks import these from `analysis._common`; the lift (#366) must not
    # have moved the import site out from under them.
    from tools import _payload

    for name in ("Profile", "KeyStats", "read_payloads", "iter_records", "fill_counts", "scalar"):
        assert getattr(_common, name) is getattr(_payload, name)


def test_load_env_overrides_the_inherited_environment(tmp_path, monkeypatch) -> None:
    env_file = tmp_path / ".env.test"
    env_file.write_text(
        "CC_OTEL_BLOB_ACCOUNT_URL=https://acct.blob.core.windows.net\nDATABASE_URL=from-file\n"
    )
    monkeypatch.delenv("CC_OTEL_BLOB_ACCOUNT_URL", raising=False)
    # marimo auto-loads the repo-root `.env` (POC database) before any cell runs
    monkeypatch.setenv("DATABASE_URL", "poc-from-marimo-dotenv")

    assert _common.load_env(env_file) == env_file
    assert os.environ["CC_OTEL_BLOB_ACCOUNT_URL"] == "https://acct.blob.core.windows.net"
    assert os.environ["DATABASE_URL"] == "from-file"  # the chosen env file wins


def test_load_env_missing_file_is_not_an_error(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("CC_OTEL_ENV_FILE", str(tmp_path / "absent"))
    assert _common.load_env() is None
