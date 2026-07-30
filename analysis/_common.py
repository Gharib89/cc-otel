"""Env loading for the analysis notebooks, plus the payload aggregation they share (#249).

The reservoir reader and the record-grain aggregation moved to ``tools._payload`` (#366) so
``tools.basis_drift`` can profile against the same primitives; they are re-exported here so
the notebooks' imports are unchanged. What stays is ``load_env`` — a marimo-kernel concern
with no place in the curation tools.
"""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

from tools._payload import (
    CROSSTAB_CARD,
    VALUE_CAP,
    KeyStats,
    Profile,
    attr_value_samples,
    fill_counts,
    iter_attrs,
    iter_records,
    read_payloads,
    scalar,
)

__all__ = [
    "CROSSTAB_CARD",
    "VALUE_CAP",
    "KeyStats",
    "Profile",
    "attr_value_samples",
    "fill_counts",
    "iter_attrs",
    "iter_records",
    "load_env",
    "read_payloads",
    "scalar",
]

_REPO_ROOT = Path(__file__).resolve().parents[1]


def load_env(env_file: str | os.PathLike[str] | None = None) -> Path | None:
    """Load a repo-root ``.env.<env>`` into ``os.environ``; return the file, or ``None``.

    The notebooks read the reservoir and marts settings from the environment
    (``cc_otel_sink.config.load_settings``), but a marimo kernel has no shell to
    ``set -a; . ./.env.interim; set +a`` into — so the load happens here instead.
    Defaults to ``.env.interim``; ``CC_OTEL_ENV_FILE`` selects another file (e.g.
    ``.env.prod``, or an absolute path). A missing file is not an error: the
    notebook then runs on whatever the environment already carries.

    ``override=True`` on purpose: marimo auto-loads the repo-root ``.env`` into the
    kernel before any cell runs, and that file is the ad-hoc ``psql`` environment — a
    bare ``DATABASE_URL`` on a read-only login plus the Azure identity vars, no
    reservoir settings at all, and a target that moves with operator housekeeping
    (interim since the POC delete, ADR-0016). Deferring to the inherited value pointed
    the notebooks at whatever that happened to be. The chosen file names the environment, so
    it wins; to target another one, set ``CC_OTEL_ENV_FILE`` rather than exporting
    individual variables.
    """
    name = env_file if env_file is not None else os.environ.get("CC_OTEL_ENV_FILE", ".env.interim")
    path = Path(name)
    if not path.is_absolute():
        path = _REPO_ROOT / path
    if not path.is_file():
        return None
    load_dotenv(path, override=True)
    return path
