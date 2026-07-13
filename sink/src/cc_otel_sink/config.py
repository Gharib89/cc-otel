"""Runtime configuration, read from the environment (no Key Vault — ACA secrets, #23)."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    database_url: str
    # Blob reservoir (ADR-0005). Either an account URL (managed identity via
    # DefaultAzureCredential) or a connection string; unset ⇒ reservoir disabled.
    blob_account_url: str | None
    blob_connection_string: str | None
    blob_container: str
    host: str
    port: int


def load_settings() -> Settings:
    return Settings(
        database_url=os.environ.get("DATABASE_URL", ""),
        blob_account_url=os.environ.get("CC_OTEL_BLOB_ACCOUNT_URL") or None,
        blob_connection_string=os.environ.get("CC_OTEL_BLOB_CONNECTION_STRING") or None,
        blob_container=os.environ.get("CC_OTEL_BLOB_CONTAINER", "raw"),
        # localhost only — the collector fronts the sink in the same Container App (#6);
        # the sink must never get its own external ingress.
        host=os.environ.get("CC_OTEL_SINK_HOST", "127.0.0.1"),
        port=int(os.environ.get("CC_OTEL_SINK_PORT", "8080")),
    )
