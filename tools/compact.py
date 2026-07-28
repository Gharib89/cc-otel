"""Compact each frozen reservoir partition into one parquet file (#360, ADR-0015).

A reservoir read costs ~22-31 s per full-day partition, and the driver is **file count, not
bytes**: 860 gzipped blobs read in 9.6 s with zero network against 2.83 MB of payload, so
~11 ms of per-file overhead sits on both sides of the wire (#352). One parquet per
``(signal, day)`` — a single ``json VARCHAR`` column holding the payload text, so no OTLP
schema is committed to — collapses fetch from 10-15 s to ~1 s per partition.

The compacted container is **derived, additive and rebuildable**: ``tools.replay`` and
``tools.scrub`` only ever see ``raw``, which stays the replay source (ADR-0005). Never
compacts today's partition — ``blob.py`` names each blob from ingest wall-clock UTC, so
every ``dt < today`` is frozen at UTC midnight while today's is still growing; the analysis
read path falls back to ``raw`` for it.

Default target is every frozen partition with no compacted counterpart, so one run catches
up whatever is missing no matter when it last ran. Dry-run by default; ``--execute`` writes.

    uv run python -m tools.compact                              # dry-run: the catch-up plan
    uv run python -m tools.compact --execute
    uv run python -m tools.compact --since 2026-07-20 --until 2026-07-22 --rebuild --execute

``--rebuild`` re-derives partitions that already have a counterpart — needed after
``tools.scrub`` rewrites a raw window, because the compacted copy of that window still
carries the newly ``denied`` key (docs/agents/column-curation.md section 6).
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from datetime import UTC, date, datetime
from pathlib import Path
from typing import NamedTuple

import duckdb
from azure.core.exceptions import ResourceNotFoundError
from cc_otel_sink.config import load_settings

from ._progress import Progress
from ._reservoir import CurationReservoir, configure_duckdb
from ._window import compacted_name, partition_glob
from .signals import ROUTES


class MissingCompactedContainer(RuntimeError):
    """The compacted container is not provisioned — the guaranteed first-run failure.

    ADR-0015 declares the container in ``iac/modules/storage.bicep`` and never lets the tool
    create it, so every environment hits this once: before the deploy lands, the Azure SDK
    answers a plain listing with an opaque ``ContainerNotFound`` traceback.
    """

    def __init__(self, container: str) -> None:
        super().__init__(
            f"container '{container}' does not exist — deploy iac/ to this environment "
            "(manual workflow_dispatch) before compacting, or point "
            "CC_OTEL_BLOB_COMPACTED_CONTAINER at an existing container"
        )


def partition_days(prefixes: list[str]) -> list[date]:
    """Dates of the ``dt=<YYYY-MM-DD>/`` child prefixes in ``prefixes``, oldest first.

    Ascending so a catch-up run works through the backlog in ingest order; anything that
    is not a ``dt=`` partition is ignored rather than raising, so an unrelated child
    prefix cannot break discovery.
    """
    days = []
    for name in prefixes:
        leaf = name.rstrip("/").rsplit("/", 1)[-1]
        if leaf.startswith("dt="):
            days.append(date.fromisoformat(leaf.removeprefix("dt=")))
    return sorted(days)


def plan(
    raw: CurationReservoir,
    compacted: CurationReservoir,
    signals: tuple[str, ...],
    today: date,
    since: date | None = None,
    until: date | None = None,
    rebuild: bool = False,
) -> list[tuple[str, date]]:
    """The ``(signal, day)`` partitions to build, discovered from ``raw``.

    Every frozen partition (``dt < today``) that has no counterpart in ``compacted``,
    optionally bounded by ``since``/``until``. ``rebuild`` ignores existing counterparts —
    the escape hatch for a raw window that ``tools.scrub`` rewrote after compaction.
    """
    todo: list[tuple[str, date]] = []
    for signal in signals:
        prefix = f"signal={signal}/"
        try:
            existing = set(compacted.list_names(prefix))
        except ResourceNotFoundError as err:
            raise MissingCompactedContainer(compacted.container_name) from err
        for day in partition_days(raw.list_prefixes(prefix)):
            if day >= today or (since and day < since) or (until and day > until):
                continue
            if not rebuild and compacted_name(signal, day) in existing:
                continue
            todo.append((signal, day))
    return todo


def compact_partition(con: duckdb.DuckDBPyConnection, source_glob: str, target: Path) -> None:
    """Write one partition's payload text to a zstd parquet at ``target``.

    Takes the source glob rather than a container so the build is exercisable over local
    files. DuckDB's Azure extension reads but does not write, hence the local file the
    caller uploads.
    """
    source = source_glob.replace("'", "''")
    destination = str(target).replace("\\", "/").replace("'", "''")
    con.execute(
        f"COPY (SELECT json FROM read_json_objects('{source}', format='unstructured')) "
        f"TO '{destination}' (FORMAT parquet, COMPRESSION zstd)"
    )


class Counts(NamedTuple):
    """Partitions built and total compressed bytes uploaded."""

    partitions: int
    bytes_written: int


def run(
    con: duckdb.DuckDBPyConnection,
    compacted: CurationReservoir,
    raw_container: str,
    partitions: list[tuple[str, date]],
) -> Counts:
    """Build and upload every partition in ``partitions``, overwriting any counterpart.

    Idempotent per partition: the parquet is derived only from that partition's raw blobs,
    so a re-run of the same partition produces the same content and the upload overwrites.
    """
    built = written = 0
    progress = Progress("compact partitions", total=len(partitions))
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "part-0.parquet"
        for signal, day in partitions:
            compact_partition(con, partition_glob(raw_container, signal, day), target)
            data = target.read_bytes()
            compacted.overwrite(compacted_name(signal, day), data)
            built += 1
            written += len(data)
            progress.tick()
    progress.done()
    return Counts(built, written)


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument(
        "--since", type=date.fromisoformat, help="restrict to partitions from this date on"
    )
    p.add_argument(
        "--until", type=date.fromisoformat, help="restrict to partitions up to this date"
    )
    p.add_argument("--signal", choices=ROUTES, help="restrict to one blob signal; default both")
    p.add_argument(
        "--rebuild",
        action="store_true",
        help="re-derive partitions that already have a counterpart (e.g. after tools.scrub)",
    )
    p.add_argument("--execute", action="store_true", help="build + upload (default: dry-run)")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    settings = load_settings()
    if not settings.blob_compacted_container:
        print("set CC_OTEL_BLOB_COMPACTED_CONTAINER to the compacted container", file=sys.stderr)
        return 2

    signals = (args.signal,) if args.signal else ROUTES
    target_container = settings.blob_compacted_container
    raw = CurationReservoir.from_settings(settings)
    compacted = CurationReservoir.from_settings(settings, container=target_container)
    try:
        try:
            partitions = plan(
                raw,
                compacted,
                signals,
                datetime.now(UTC).date(),
                args.since,
                args.until,
                args.rebuild,
            )
        except MissingCompactedContainer as err:
            print(err, file=sys.stderr)
            return 2
        counts = Counts(len(partitions), 0)
        if args.execute and partitions:
            con = duckdb.connect()
            try:
                configure_duckdb(con, settings)
                counts = run(con, compacted, settings.blob_container, partitions)
            finally:
                con.close()
    finally:
        raw.close()
        compacted.close()

    verb = "compacted" if args.execute else "would compact"
    print(
        f"Compact -> {target_container}: {verb} {counts.partitions} partition(s)"
        + (f", {counts.bytes_written / 1e6:.2f} MB written" if args.execute else "")
        + ("" if args.execute else " — dry-run, pass --execute to write")
    )
    for signal, day in partitions:
        print(f"  {signal:<8} {day:%Y-%m-%d}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
