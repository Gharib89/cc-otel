"""Blob-reservoir access for the curation tools.

Built from the sink's own ``Settings`` (``CC_OTEL_BLOB_*``) so the tools read the same
container the sink writes — or, with ``from_settings``' container override, the compacted
container beside it (ADR-0015), which the sink never touches. Two consumers:

* ``CurationReservoir`` — list / download / overwrite, for ``tools.scrub``, ``tools.replay``
  and ``tools.compact`` (the sink's ``BlobReservoir`` only writes new blobs).
* ``configure_duckdb`` — register an Azure secret on a DuckDB connection so ``tools.sweep``,
  ``tools.compact`` and the ``analysis`` notebooks can read ``azure://…`` over the reservoir.
  The secret is account-scoped, so it reaches both containers.
"""

from __future__ import annotations

from dataclasses import replace
from typing import TYPE_CHECKING
from urllib.parse import urlparse

from cc_otel_sink.blob_backend import (
    ConnectionStringBackend,
    ManagedIdentityBackend,
    build_container_client,
    select_backend,
)
from cc_otel_sink.config import Settings

if TYPE_CHECKING:
    import duckdb
    from azure.storage.blob import ContainerClient


class ReservoirUnconfigured(RuntimeError):
    """Neither CC_OTEL_BLOB_CONNECTION_STRING nor CC_OTEL_BLOB_ACCOUNT_URL is set."""

    def __init__(
        self, msg: str = "set CC_OTEL_BLOB_CONNECTION_STRING or CC_OTEL_BLOB_ACCOUNT_URL"
    ) -> None:
        super().__init__(msg)


def _account_name(account_url: str) -> str:
    # https://<account>.blob.core.windows.net -> <account>
    return urlparse(account_url).hostname.split(".")[0]  # type: ignore[union-attr]


class CurationReservoir:
    def __init__(self, container_client: ContainerClient, credential=None) -> None:
        self._container = container_client
        self._credential = credential

    @classmethod
    def from_settings(cls, settings: Settings, container: str | None = None) -> CurationReservoir:
        """Build a client for ``settings.blob_container``, or for ``container`` instead.

        The override exists for the compacted reservoir (ADR-0015), which lives in a second
        container on the same account: swapping the field keeps the auth-precedence rule in
        ``blob_backend`` as the only copy rather than growing a parallel builder.
        """
        if container is not None:
            settings = replace(settings, blob_container=container)
        built = build_container_client(settings)
        if built is None:
            raise ReservoirUnconfigured
        client, credential = built
        return cls(client, credential)

    @property
    def container_name(self) -> str:
        return self._container.container_name

    def list_names(self, prefix: str) -> list[str]:
        return [b.name for b in self._container.list_blobs(name_starts_with=prefix)]

    def list_prefixes(self, prefix: str) -> list[str]:
        """Immediate child *prefixes* of ``prefix`` — Hive partition discovery (compact).

        ``walk_blobs`` with a ``/`` delimiter returns one entry per partition instead of one
        per blob, so discovering which days exist costs a directory listing rather than a
        scan of ~20k blob names. Child blobs come back too and are filtered out by the
        trailing delimiter.
        """
        return [
            item.name
            for item in self._container.walk_blobs(name_starts_with=prefix, delimiter="/")
            if item.name.endswith("/")
        ]

    def download(self, name: str) -> bytes:
        return self._container.download_blob(name).readall()

    def overwrite(self, name: str, data: bytes) -> None:
        self._container.upload_blob(name, data, overwrite=True)

    def close(self) -> None:
        self._container.close()
        if self._credential is not None:
            self._credential.close()


def configure_duckdb(con: duckdb.DuckDBPyConnection, settings: Settings) -> None:
    """Install the Azure extension and register a secret from ``settings``."""
    con.execute("INSTALL azure; LOAD azure;")
    match select_backend(settings):
        case ConnectionStringBackend(connection_string=connection_string):
            conn_str = connection_string.replace("'", "''")
            con.execute(
                f"CREATE OR REPLACE SECRET blob (TYPE azure, CONNECTION_STRING '{conn_str}')"
            )
        case ManagedIdentityBackend(account_url=account_url):
            from azure.identity import DefaultAzureCredential

            account = _account_name(account_url)
            # Fetch one OAuth token up front rather than PROVIDER credential_chain: DuckDB's chain
            # re-acquires a token on blob opens and throttles/expires mid-read on large partitions
            # (#99). One prefetched token (valid ~1h — ample for a sweep) is registered statically.
            credential = DefaultAzureCredential()
            try:
                token = credential.get_token("https://storage.azure.com/.default").token
            finally:
                credential.close()
            token = token.replace("'", "''")
            con.execute(
                "CREATE OR REPLACE SECRET blob (TYPE azure, PROVIDER access_token, "
                f"ACCESS_TOKEN '{token}', ACCOUNT_NAME '{account}')"
            )
        case None:
            raise ReservoirUnconfigured
