"""Integration: the kept-basis CHECK constraints reject what they claim to (#366).

The constraints are the durable half of #366 — they are what stops a future PR
minting an unwatched `kept` row — so each rejection is proved against a real
Postgres, not read off the DDL. A CHECK passes when its expression is TRUE *or
NULL*, and both constraints are written to never yield NULL; the orphan-partner
case below is the one that catches a regression back to a plain `=` comparison.
"""

from __future__ import annotations

import psycopg
import pytest

_INSERT = (
    "INSERT INTO meta.column_registry"
    " (signal, signal_name, attr_path, status, kept_basis, basis_partner)"
    " VALUES ('metrics', '*', 'test.basis_probe', %s, %s, %s)"
)


@pytest.mark.parametrize(
    ("status", "kept_basis", "basis_partner"),
    [
        pytest.param("kept", None, None, id="kept-with-no-basis"),
        pytest.param("kept", "invented", None, id="basis-outside-the-closed-set"),
        pytest.param("denied", "nature", None, id="basis-on-a-non-kept-row"),
        pytest.param("kept", "collinear", None, id="collinear-with-no-partner"),
        pytest.param("kept", "nature", "os.type", id="partner-without-collinear"),
        pytest.param("denied", None, "os.type", id="orphan-partner-on-a-null-basis"),
    ],
)
def test_rejected(conn, status: str, kept_basis: str | None, basis_partner: str | None) -> None:
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(_INSERT, (status, kept_basis, basis_partner))


@pytest.mark.parametrize(
    ("status", "kept_basis", "basis_partner"),
    [
        ("kept", "nature", None),
        ("kept", "constant", None),
        ("kept", "thin", None),
        ("kept", "redundant", None),
        ("kept", "collinear", "os.type"),
        ("denied", None, None),
    ],
)
def test_accepted(conn, status: str, kept_basis: str | None, basis_partner: str | None) -> None:
    conn.execute(_INSERT, (status, kept_basis, basis_partner))
    conn.execute("DELETE FROM meta.column_registry WHERE attr_path = 'test.basis_probe'")
