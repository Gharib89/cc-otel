"""Best-effort redacted-raw blob reservoir (ADR-0005).

One gzipped file per batch, Hive-partitioned ``signal=<metrics|logs>/dt=<date>/``.
Written after the 200 response via a background task; any failure logs a warning
and never affects ingest. Unconfigured ⇒ a no-op :class:`NullReservoir`.
"""

from __future__ import annotations

import gzip
import logging
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Protocol

from .config import Settings

if TYPE_CHECKING:
    from azure.identity import DefaultAzureCredential
    from azure.storage.blob import ContainerClient

logger = logging.getLogger("cc_otel_sink.blob")


class Reservoir(Protocol):
    """The reservoir contract the ingest path depends on — a real blob writer or
    a no-op stand-in, so callers never branch on ``None``."""

    def write(self, signal: str, payload: bytes) -> None: ...

    def close(self) -> None: ...


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
    construction is the caller's thin adapter (:meth:`BlobReservoir.from_settings`).
    """
    if settings.blob_connection_string:
        return ConnectionStringBackend(settings.blob_connection_string, settings.blob_container)
    if settings.blob_account_url:
        return ManagedIdentityBackend(settings.blob_account_url, settings.blob_container)
    return None


class NullReservoir:
    """No-op reservoir used when blob storage is unconfigured (ADR-0005)."""

    def write(self, signal: str, payload: bytes) -> None:
        pass

    def close(self) -> None:
        pass


class BlobReservoir:
    def __init__(
        self, container_client: ContainerClient, credential: DefaultAzureCredential | None = None
    ) -> None:
        self._container = container_client
        # Kept so close() can release the credential's own transport (managed
        # identity holds a token-cache HTTP session distinct from the client's).
        self._credential = credential

    @classmethod
    def from_settings(cls, settings: Settings) -> Reservoir:
        """Build a reservoir from settings; a :class:`NullReservoir` when unconfigured."""
        try:
            from azure.storage.blob import ContainerClient
        except ImportError:  # pragma: no cover - dependency always present in prod
            return NullReservoir()

        backend = select_backend(settings)
        if isinstance(backend, ConnectionStringBackend):
            client = ContainerClient.from_connection_string(
                backend.connection_string, backend.container
            )
            return cls(client)
        if isinstance(backend, ManagedIdentityBackend):
            from azure.identity import DefaultAzureCredential

            credential = DefaultAzureCredential()
            client = ContainerClient(
                backend.account_url,
                backend.container,
                credential=credential,
            )
            return cls(client, credential)
        return NullReservoir()

    def write(self, signal: str, payload: bytes) -> None:
        """Upload one gzipped batch. Best-effort: warns on failure, never raises."""
        try:
            now = datetime.now(UTC)
            name = f"signal={signal}/dt={now:%Y-%m-%d}/{now:%H%M%S}-{uuid.uuid4().hex}.json.gz"
            self._container.upload_blob(name, gzip.compress(payload), overwrite=False)
        except Exception:
            logger.warning("blob reservoir write failed for signal=%s", signal, exc_info=True)

    def close(self) -> None:
        """Release the client's (and any credential's) transport (sockets/threads)."""
        self._container.close()
        if self._credential is not None:
            self._credential.close()
