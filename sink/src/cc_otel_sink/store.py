"""Transactional Postgres writer with batch-hash idempotency (#7).

Each batch is written in a single transaction that first claims the batch hash in
``meta.processed_batches``; a replayed batch loses the ``ON CONFLICT`` race and is
a no-op. The transaction commits before the caller returns 200; any failure
propagates so the endpoint answers 5xx and the collector retries.
"""

from __future__ import annotations

from typing import Any

from psycopg_pool import AsyncConnectionPool

from .column_spec import table_columns

# Promoted columns per raw table, derived from the authoritative spec. Insert
# order is free — ``_insert_sql`` names its columns, so it need not match the DDL
# ordinal order (the spec_sync gate compares column sets + types, not ordinals).
METRIC_COLUMNS = table_columns("metrics")
EVENT_COLUMNS = table_columns("events")


def _insert_sql(table: str, columns: tuple[str, ...]) -> str:
    placeholders = ", ".join(["%s"] * len(columns))
    return f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({placeholders})"


_METRICS_INSERT = _insert_sql("raw.metrics", METRIC_COLUMNS)
_EVENTS_INSERT = _insert_sql("raw.events", EVENT_COLUMNS)
_CLAIM_BATCH = (
    "INSERT INTO meta.processed_batches (batch_hash) VALUES (%s) "
    "ON CONFLICT (batch_hash) DO NOTHING"
)


def _to_tuple(row: dict[str, Any], columns: tuple[str, ...]) -> tuple[Any, ...]:
    return tuple(row.get(c) for c in columns)


class Store:
    def __init__(self, pool: AsyncConnectionPool) -> None:
        self._pool = pool

    @classmethod
    def from_dsn(cls, dsn: str) -> Store:
        pool = AsyncConnectionPool(dsn, open=False)
        return cls(pool)

    async def open(self) -> None:
        await self._pool.open()

    async def close(self) -> None:
        await self._pool.close()

    async def write_batch(
        self,
        metrics: list[dict[str, Any]],
        events: list[dict[str, Any]],
        batch_hash: str,
    ) -> bool:
        """Write one batch atomically. Returns True if written, False if a duplicate."""
        async with self._pool.connection() as conn:
            async with conn.transaction():
                async with conn.cursor() as cur:
                    await cur.execute(_CLAIM_BATCH, (batch_hash,))
                    if cur.rowcount == 0:
                        return False  # already processed — no-op, commit nothing new
                    if metrics:
                        await cur.executemany(
                            _METRICS_INSERT,
                            [_to_tuple(r, METRIC_COLUMNS) for r in metrics],
                        )
                    if events:
                        await cur.executemany(
                            _EVENTS_INSERT,
                            [_to_tuple(r, EVENT_COLUMNS) for r in events],
                        )
        return True
