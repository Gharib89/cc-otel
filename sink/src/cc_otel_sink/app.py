"""FastAPI OTLP/JSON sink.

Trusts the collector (auth is collector-side, #6); binds localhost only. Per
request: decode → redact (#8) → hash redacted payload → transactional Postgres
write before the 200 (#7) → best-effort blob write after (ADR-0005).
"""

from __future__ import annotations

import hashlib
import json
import logging
from collections.abc import Callable
from contextlib import asynccontextmanager
from typing import Any

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request

from .blob import BlobReservoir
from .config import Settings, load_settings
from .counters import drift_strip_count, record_drift_strips
from .parser import parse_events, parse_metrics
from .redaction import redact
from .store import Store

logger = logging.getLogger("cc_otel_sink")


def get_store(request: Request) -> Store:
    store = request.app.state.store
    if store is None:
        raise HTTPException(503, "sink not configured with a database")
    return store


def get_blob(request: Request) -> BlobReservoir | None:
    return request.app.state.blob


async def _ingest(
    request: Request,
    background_tasks: BackgroundTasks,
    signal: str,
    parse_fn: Callable[[dict[str, Any]], list[dict[str, Any]]],
    store: Store,
    blob: BlobReservoir | None,
) -> dict[str, Any]:
    raw = await request.body()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise HTTPException(400, "invalid OTLP/JSON body") from exc

    result = redact(payload)
    if result.drift_strips:
        record_drift_strips(result.drift_strips)
        logger.warning(
            "redaction stripped %d non-empty defense-in-depth field(s); a client "
            "content gate has drifted",
            result.drift_strips,
        )

    # Canonical serialization: the hash key AND the blob content. Redacted, so a
    # replayed batch is byte-identical and hash-matches (#7/#8).
    redacted_bytes = json.dumps(result.payload, separators=(",", ":"), sort_keys=True).encode()
    batch_hash = hashlib.sha256(redacted_bytes).hexdigest()

    metrics = parse_fn(result.payload) if signal == "metrics" else []
    events = parse_fn(result.payload) if signal == "logs" else []
    try:
        await store.write_batch(metrics, events, batch_hash)
    except Exception as exc:
        logger.exception("postgres write failed")
        raise HTTPException(503, "postgres write failed") from exc

    if blob is not None:
        background_tasks.add_task(blob.write, signal, redacted_bytes)

    # OTLP/HTTP success envelope.
    return {"partialSuccess": {}}


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or load_settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        store = Store.from_dsn(settings.database_url) if settings.database_url else None
        if store is not None:
            await store.open()
        app.state.store = store
        app.state.blob = BlobReservoir.from_settings(settings)
        try:
            yield
        finally:
            if store is not None:
                await store.close()

    app = FastAPI(title="cc-otel sink", lifespan=lifespan)

    @app.get("/healthz")
    async def healthz() -> dict[str, Any]:
        return {"status": "ok", "drift_strips": drift_strip_count()}

    @app.post("/v1/metrics")
    async def ingest_metrics(
        request: Request,
        background_tasks: BackgroundTasks,
        store: Store = Depends(get_store),
        blob: BlobReservoir | None = Depends(get_blob),
    ) -> dict[str, Any]:
        return await _ingest(
            request, background_tasks, "metrics", parse_metrics, store, blob
        )

    @app.post("/v1/logs")
    async def ingest_logs(
        request: Request,
        background_tasks: BackgroundTasks,
        store: Store = Depends(get_store),
        blob: BlobReservoir | None = Depends(get_blob),
    ) -> dict[str, Any]:
        return await _ingest(request, background_tasks, "logs", parse_events, store, blob)

    return app


app = create_app()
