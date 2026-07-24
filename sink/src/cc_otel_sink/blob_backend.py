"""Settings -> authenticated blob container access — the one copy of the rule.

The "connection string wins, else account URL + managed identity, else none"
precedence lives here once. Two consumers depend on it: the sink's
:class:`~cc_otel_sink.blob.BlobReservoir` and the curation tools
(``tools._reservoir`` — both ``CurationReservoir`` and ``configure_duckdb``).
Policy on the ``None`` case stays with each caller (ADR-0005 best-effort vs raise).

Strict-typed: ``sink/src`` is under mypy ``--strict``. No DuckDB import — the
sink must never pull DuckDB in.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from .config import Settings

if TYPE_CHECKING:
    from azure.identity import DefaultAzureCredential
    from azure.storage.blob import ContainerClient


@dataclass(frozen=True)
class ConnectionStringBackend:
    connection_string: str
    container: str


@dataclass(frozen=True)
class ManagedIdentityBackend:
    account_url: str
    container: str


Backend = ConnectionStringBackend | ManagedIdentityBackend | None


def select_backend(settings: Settings) -> Backend:
    """Pure choice of blob backend from settings; ``None`` when unconfigured.

    Connection string wins over account URL. No Azure SDK objects are touched —
    construction is :func:`build_container_client`.
    """
    if settings.blob_connection_string:
        return ConnectionStringBackend(settings.blob_connection_string, settings.blob_container)
    if settings.blob_account_url:
        return ManagedIdentityBackend(settings.blob_account_url, settings.blob_container)
    return None


def build_container_client(
    settings: Settings,
) -> tuple[ContainerClient, DefaultAzureCredential | None] | None:
    """Eager container client from :func:`select_backend`'s choice; ``None`` unconfigured.

    Construction is offline and cheap, so no factory. The connection-string path
    returns ``(client, None)``; the account-URL path constructs a
    :class:`DefaultAzureCredential` and returns it alongside the client so callers
    can close its transport. ``ImportError`` (Azure SDK absent) propagates to the
    caller, which decides the fallback.
    """
    backend = select_backend(settings)
    if backend is None:
        return None

    from azure.storage.blob import ContainerClient

    if isinstance(backend, ConnectionStringBackend):
        client = ContainerClient.from_connection_string(
            backend.connection_string, backend.container
        )
        return client, None

    from azure.identity import DefaultAzureCredential

    credential = DefaultAzureCredential()
    client = ContainerClient(backend.account_url, backend.container, credential=credential)
    return client, credential
