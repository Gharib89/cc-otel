"""Blob-reservoir access for the curation tools.

Built from the sink's own ``Settings`` (``CC_OTEL_BLOB_*``) so the tools read the same
container the sink writes. Two consumers:

* ``CurationReservoir`` — list / download / overwrite, for ``tools.scrub`` and
  ``tools.replay`` (the sink's ``BlobReservoir`` only writes new blobs).
* ``configure_duckdb`` — register an Azure secret on a DuckDB connection so
  ``tools.sweep`` can ``read_json_objects('azure://…')`` over the reservoir.
"""

from __future__ import annotations

from typing import TYPE_CHECKING
from urllib.parse import urlparse

from cc_otel_sink.config import Settings

if TYPE_CHECKING:
    import duckdb
    from azure.storage.blob import ContainerClient


class ReservoirUnconfigured(RuntimeError):
    """Neither CC_OTEL_BLOB_CONNECTION_STRING nor CC_OTEL_BLOB_ACCOUNT_URL is set."""


def _account_name(account_url: str) -> str:
    # https://<account>.blob.core.windows.net -> <account>
    return urlparse(account_url).hostname.split(".")[0]  # type: ignore[union-attr]


class CurationReservoir:
    def __init__(self, container_client: ContainerClient, credential=None) -> None:
        self._container = container_client
        self._credential = credential

    @classmethod
    def from_settings(cls, settings: Settings) -> CurationReservoir:
        from azure.storage.blob import ContainerClient

        if settings.blob_connection_string:
            return cls(
                ContainerClient.from_connection_string(
                    settings.blob_connection_string, settings.blob_container
                )
            )
        if settings.blob_account_url:
            from azure.identity import DefaultAzureCredential

            credential = DefaultAzureCredential()
            return cls(
                ContainerClient(
                    settings.blob_account_url, settings.blob_container, credential=credential
                ),
                credential,
            )
        raise ReservoirUnconfigured

    def list_names(self, prefix: str) -> list[str]:
        return [b.name for b in self._container.list_blobs(name_starts_with=prefix)]

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
    if settings.blob_connection_string:
        conn_str = settings.blob_connection_string.replace("'", "''")
        con.execute(f"CREATE OR REPLACE SECRET blob (TYPE azure, CONNECTION_STRING '{conn_str}')")
    elif settings.blob_account_url:
        account = _account_name(settings.blob_account_url)
        con.execute(
            "CREATE OR REPLACE SECRET blob "
            f"(TYPE azure, PROVIDER credential_chain, ACCOUNT_NAME '{account}')"
        )
    else:
        raise ReservoirUnconfigured
