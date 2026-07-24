"""Best-effort redacted-raw blob reservoir (ADR-0005).

One gzipped file per batch, Hive-partitioned ``signal=<metrics|logs>/dt=<date>/``.
Written after the 200 response via a background task; any failure logs a warning
and never affects ingest. Unconfigured ⇒ a no-op :class:`NullReservoir`.
"""

from __future__ import annotations

import gzip
import logging
import uuid
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Protocol

from .blob_backend import build_container_client
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
            built = build_container_client(settings)
        except ImportError:  # pragma: no cover - dependency always present in prod
            return NullReservoir()
        if built is None:
            return NullReservoir()
        client, credential = built
        return cls(client, credential)

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
