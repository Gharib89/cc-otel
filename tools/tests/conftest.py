"""Shared fixtures for the curation-tool tests."""

from __future__ import annotations

import pytest


class FakeReservoir:
    """Dict-backed ``CurationReservoir`` stand-in for scrub / replay unit tests.

    Implements the five methods the tools use (``list_names``, ``list_prefixes``,
    ``download``, ``overwrite``, ``close``) over an in-memory ``{name: bytes}`` map, and
    records every overwrite so a test can assert dry-run wrote nothing.
    """

    def __init__(self, blobs: dict[str, bytes] | None = None) -> None:
        self.blobs = dict(blobs or {})
        self.overwrites: list[str] = []
        self.closed = False

    def list_names(self, prefix: str) -> list[str]:
        return [name for name in self.blobs if name.startswith(prefix)]

    def list_prefixes(self, prefix: str) -> list[str]:
        """Immediate child prefixes of ``prefix`` — the real client's ``walk_blobs`` shape."""
        depth = prefix.count("/") + 1
        return sorted(
            {
                "/".join(name.split("/")[:depth]) + "/"
                for name in self.blobs
                if name.startswith(prefix) and name.count("/") >= depth
            }
        )

    def download(self, name: str) -> bytes:
        return self.blobs[name]

    def overwrite(self, name: str, data: bytes) -> None:
        self.blobs[name] = data
        self.overwrites.append(name)

    def close(self) -> None:
        self.closed = True


@pytest.fixture
def fake_reservoir():
    """Factory for a seeded :class:`FakeReservoir` — ``fake_reservoir({name: blob})``."""
    return FakeReservoir
