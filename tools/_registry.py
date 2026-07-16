"""Match extracted key paths against ``meta.column_registry``.

Pure matching (``Registry``) is split from the Postgres load (``load_registry``) so the
diff rule can be unit-tested without a database.

Matching rule — an extracted ``(signal, signal_name, attr_path)`` is *known* iff the
registry holds a row with the same ``signal`` and ``attr_path`` whose ``signal_name`` is
either the same name or the wildcard ``'*'``. This mirrors the registry's grain: an attr
with uniform meaning is recorded once at ``'*'``; one whose meaning differs by signal name
gets a row per name, so a known key seen under a *new* name is still surfaced.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from ._keypaths import KeyPath

if TYPE_CHECKING:
    from psycopg import Connection


@dataclass(frozen=True)
class Diff:
    # Keys with no registry row at all under their signal — need classifying.
    unclassified: list[KeyPath]
    # Keys classified 'denied' yet present in the (redacted) blob — a redaction leak.
    leaks: list[KeyPath]


class Registry:
    """The classified key set, indexed for wildcard-aware lookup."""

    def __init__(self, rows: list[tuple[str, str, str, str]]) -> None:
        # (signal, attr_path) -> {signal_name: status}
        self._index: dict[tuple[str, str], dict[str, str]] = {}
        for signal, signal_name, attr_path, status in rows:
            self._index.setdefault((signal, attr_path), {})[signal_name] = status

    def status_of(self, signal: str, signal_name: str, attr_path: str) -> str | None:
        """Return the status for a key path, matching the exact name then ``'*'``."""
        names = self._index.get((signal, attr_path))
        if names is None:
            return None
        return names.get(signal_name) or names.get("*")

    def diff(self, extracted: set[KeyPath]) -> Diff:
        unclassified: list[KeyPath] = []
        leaks: list[KeyPath] = []
        for signal, signal_name, attr_path in sorted(extracted):
            status = self.status_of(signal, signal_name, attr_path)
            if status is None:
                unclassified.append((signal, signal_name, attr_path))
            elif status == "denied":
                leaks.append((signal, signal_name, attr_path))
        return Diff(unclassified=unclassified, leaks=leaks)


def load_registry(conn: Connection) -> Registry:
    """Load every ``meta.column_registry`` row into a ``Registry``."""
    with conn.cursor() as cur:
        cur.execute("SELECT signal, signal_name, attr_path, status FROM meta.column_registry")
        rows = cur.fetchall()
    return Registry([(r[0], r[1], r[2], r[3]) for r in rows])
