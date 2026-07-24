"""Blob backend: the one auth-precedence rule + eager client construction."""

from __future__ import annotations

import pytest
from cc_otel_sink.blob_backend import (
    ConnectionStringBackend,
    ManagedIdentityBackend,
    build_container_client,
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


class _FakeContainerClient:
    """Records how it was constructed so the branch can be asserted."""

    def __init__(self, account_url=None, container=None, credential=None) -> None:
        self.account_url = account_url
        self.container = container
        self.credential = credential
        self.from_conn: tuple | None = None

    @classmethod
    def from_connection_string(cls, conn_str, container):
        inst = cls()
        inst.from_conn = (conn_str, container)
        return inst


class _FakeCredential:
    def __init__(self, *_args, **_kwargs) -> None:
        pass


@pytest.fixture
def fake_azure(monkeypatch):
    monkeypatch.setattr("azure.storage.blob.ContainerClient", _FakeContainerClient)
    monkeypatch.setattr("azure.identity.DefaultAzureCredential", _FakeCredential)


def test_build_container_client_connection_string_path(fake_azure):
    client, credential = build_container_client(
        _settings(blob_connection_string="cs", blob_container="raw")
    )
    # Constructed via from_connection_string with the container; no credential.
    assert client.from_conn == ("cs", "raw")
    assert credential is None


def test_build_container_client_account_url_path(fake_azure):
    client, credential = build_container_client(
        _settings(blob_account_url="https://acct", blob_container="raw")
    )
    # Constructed with the account URL, container, and a passed-through credential.
    assert client.account_url == "https://acct"
    assert client.container == "raw"
    assert isinstance(credential, _FakeCredential)
    assert client.credential is credential


def test_build_container_client_unconfigured_is_none(fake_azure):
    assert build_container_client(_settings()) is None
