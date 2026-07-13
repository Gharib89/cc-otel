"""Best-effort redacted-raw blob reservoir (ADR-0005).

One gzipped file per batch, Hive-partitioned ``signal=<metrics|logs>/dt=<date>/``.
Written after the 200 response via a background task; any failure logs a warning
and never affects ingest. Unconfigured ⇒ a no-op reservoir.
"""

from __future__ import annotations

import gzip
import logging
import uuid
from datetime import UTC, datetime
from typing import TYPE_CHECKING

from .config import Settings

if TYPE_CHECKING:
    from azure.storage.blob import ContainerClient

logger = logging.getLogger("cc_otel_sink.blob")


class BlobReservoir:
    def __init__(self, container_client: ContainerClient, credential=None) -> None:
        self._container = container_client
        # Kept so close() can release the credential's own transport (managed
        # identity holds a token-cache HTTP session distinct from the client's).
        self._credential = credential

    @classmethod
    def from_settings(cls, settings: Settings) -> BlobReservoir | None:
        """Build a reservoir from settings, or None when blob storage is unconfigured."""
        try:
            from azure.storage.blob import ContainerClient
        except ImportError:  # pragma: no cover - dependency always present in prod
            return None

        if settings.blob_connection_string:
            client = ContainerClient.from_connection_string(
                settings.blob_connection_string, settings.blob_container
            )
            return cls(client)
        elif settings.blob_account_url:
            from azure.identity import DefaultAzureCredential

            credential = DefaultAzureCredential()
            client = ContainerClient(
                settings.blob_account_url,
                settings.blob_container,
                credential=credential,
            )
            return cls(client, credential)
        return None

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
