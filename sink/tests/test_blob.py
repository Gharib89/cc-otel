"""Blob reservoir (ADR-0005): partition path, gzip, best-effort, clean close."""

from __future__ import annotations

import gzip

from cc_otel_sink.blob import (
    BlobReservoir,
    ConnectionStringBackend,
    ManagedIdentityBackend,
    NullReservoir,
    select_backend,
)
from cc_otel_sink.config import Settings


def _settings(**overrides) -> Settings:
    base = dict(
        database_url="",
        blob_account_url=None,
        blob_connection_string=None,
        blob_container="raw",
        host="127.0.0.1",
        port=8080,
    )
    base.update(overrides)
    return Settings(**base)


class FakeContainer:
    def __init__(self, fail: bool = False) -> None:
        self.uploads: list[tuple[str, bytes]] = []
        self.closed = False
        self.fail = fail

    def upload_blob(self, name, data, overwrite=False):
        if self.fail:
            raise RuntimeError("network down")
        self.uploads.append((name, data))

    def close(self):
        self.closed = True


def test_write_uploads_gzipped_partitioned_blob():
    container = FakeContainer()
    BlobReservoir(container).write("metrics", b'{"resourceMetrics":[]}')
    (name, data) = container.uploads[0]
    assert name.startswith("signal=metrics/dt=")
    assert name.endswith(".json.gz")
    assert gzip.decompress(data) == b'{"resourceMetrics":[]}'


def test_write_is_best_effort_on_failure():
    container = FakeContainer(fail=True)
    # Must not raise — a blob failure never affects ingest.
    BlobReservoir(container).write("logs", b"{}")


def test_close_releases_container():
    container = FakeContainer()
    BlobReservoir(container).close()
    assert container.closed is True


class FakeCredential:
    def __init__(self) -> None:
        self.closed = False

    def close(self):
        self.closed = True


def test_close_releases_credential_when_present():
    container = FakeContainer()
    credential = FakeCredential()
    BlobReservoir(container, credential).close()
    assert container.closed is True
    assert credential.closed is True


def test_select_backend_connection_string_wins():
    backend = select_backend(
        _settings(blob_connection_string="cs", blob_account_url="https://acct")
    )
    assert backend == ConnectionStringBackend("cs", "raw")


def test_select_backend_account_url_uses_managed_identity():
    backend = select_backend(_settings(blob_account_url="https://acct"))
    assert backend == ManagedIdentityBackend("https://acct", "raw")


def test_select_backend_unconfigured_is_none():
    assert select_backend(_settings()) is None


def test_null_reservoir_write_and_close_are_noops():
    # No backend, no client — must not raise.
    reservoir = NullReservoir()
    reservoir.write("metrics", b"{}")
    reservoir.close()
