"""FastAPI OTLP/JSON sink.

Trusts the collector (auth is collector-side, #6); binds localhost only. Per
request: decode → redact (#8) → hash redacted payload → transactional Postgres
write before the 200 (#7) → best-effort blob write after (ADR-0005).
"""

from __future__ import annotations

import gzip
import hashlib
import json
import logging
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Annotated, Any

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request

from .blob import BlobReservoir, Reservoir
from .canonical import canonical_bytes
from .config import Settings, load_settings
from .counters import gate_leak_count, record_gate_leaks
from .parser import parse_events, parse_metrics
from .redaction import redact
from .store import Store

logger = logging.getLogger("cc_otel_sink")

# signal → parser. Both endpoints run the identical pipeline; the signal only
# selects the parser (and which raw list its rows fill), so the two byte-identical
# POST endpoints register by looping this table rather than being spelled twice.
_SIGNAL_PARSERS: dict[str, Callable[[dict[str, Any]], list[dict[str, Any]]]] = {
    "metrics": parse_metrics,
    "logs": parse_events,
}


@dataclass(frozen=True)
class IngestBatch:
    """The pure result of the ingest pipeline: everything the Postgres store and
    the blob reservoir consume, derived once so the ordering invariant (redact
    before hash; the *same* canonical bytes to the hash and the blob) is a value
    dependency, not an inline comment (#7/#8, ADR-0005)."""

    redacted_payload: dict[str, Any]
    canonical_bytes: bytes
    batch_hash: str
    metrics: list[dict[str, Any]]
    events: list[dict[str, Any]]
    gate_leaks: int


def prepare_batch(payload: dict[str, Any], signal: str) -> IngestBatch:
    """Redact → canonicalize → hash → parse, in that order. Pure: no counters, no
    I/O — the caller records gate leaks and performs the writes."""
    result = redact(payload)
    # Canonical serialization: the hash key AND the blob content. Redacted, so a
    # replayed batch is byte-identical and hash-matches (#7/#8).
    cbytes = canonical_bytes(result.payload)
    batch_hash = hashlib.sha256(cbytes).hexdigest()
    rows_by_signal: dict[str, list[dict[str, Any]]] = {"metrics": [], "logs": []}
    rows_by_signal[signal] = _SIGNAL_PARSERS[signal](result.payload)
    return IngestBatch(
        redacted_payload=result.payload,
        canonical_bytes=cbytes,
        batch_hash=batch_hash,
        metrics=rows_by_signal["metrics"],
        events=rows_by_signal["logs"],
        gate_leaks=result.gate_leaks,
    )


def get_store(request: Request) -> Store:
    store: Store | None = request.app.state.store
    if store is None:
        raise HTTPException(503, "sink not configured with a database")
    return store


def get_blob(request: Request) -> Reservoir:
    blob: Reservoir = request.app.state.blob
    return blob


# Annotated deps keep the Depends() call out of the parameter default (ruff B008).
StoreDep = Annotated[Store, Depends(get_store)]
BlobDep = Annotated[Reservoir, Depends(get_blob)]


async def _ingest(
    request: Request,
    background_tasks: BackgroundTasks,
    signal: str,
    store: Store,
    blob: Reservoir,
) -> dict[str, Any]:
    raw = await request.body()
    if "gzip" in request.headers.get("content-encoding", "").lower():
        raw = gzip.decompress(raw)
    try:
        payload = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as exc:
        raise HTTPException(400, "invalid OTLP/JSON body") from exc

    batch = prepare_batch(payload, signal)
    if batch.gate_leaks:
        record_gate_leaks(batch.gate_leaks)
        logger.warning(
            "redaction stripped %d non-empty defense-in-depth field(s); a client "
            "content gate has leaked",
            batch.gate_leaks,
        )

    try:
        await store.write_batch(batch.metrics, batch.events, batch.batch_hash)
    except Exception as exc:
        logger.exception("postgres write failed")
        raise HTTPException(503, "postgres write failed") from exc

    background_tasks.add_task(blob.write, signal, batch.canonical_bytes)

    # OTLP/HTTP success envelope.
    return {"partialSuccess": {}}


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or load_settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        store = Store.from_dsn(settings.database_url) if settings.database_url else None
        if store is not None:
            await store.open()
        blob = BlobReservoir.from_settings(settings)
        app.state.store = store
        app.state.blob = blob
        try:
            yield
        finally:
            if store is not None:
                await store.close()
            blob.close()

    app = FastAPI(title="cc-otel sink", lifespan=lifespan)

    @app.get("/healthz")
    async def healthz() -> dict[str, Any]:
        return {"status": "ok", "gate_leaks": gate_leak_count()}

    # The metrics and logs endpoints are byte-identical bar the signal; register
    # both from the one routing table (#16) instead of spelling each out.
    def _make_endpoint(signal: str) -> Callable[..., Any]:
        async def ingest(
            request: Request,
            background_tasks: BackgroundTasks,
            store: StoreDep,
            blob: BlobDep,
        ) -> dict[str, Any]:
            return await _ingest(request, background_tasks, signal, store, blob)

        return ingest

    for signal in _SIGNAL_PARSERS:
        app.add_api_route(f"/v1/{signal}", _make_endpoint(signal), methods=["POST"])

    return app


app = create_app()
