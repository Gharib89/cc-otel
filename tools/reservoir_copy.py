"""Copy interim's reservoir partitions from the cutover floor up into production (#246, ADR-0020).

The reservoir half of the cutover data policy, twin of ``tools.cutover_copy``'s raw-Postgres
half: the same window, the same floor, the same direction. Blob paths are **identical** on both
ends -- ``signal=<metrics|logs>/dt=<YYYY-MM-DD>/<HHMMSS>-<uuid4>.json.gz`` -- so production's
reservoir becomes replay- and curation-capable back to the floor (ADR-0017).

    uv run python -m tools.reservoir_copy            # dry-run: what is missing in production
    uv run python -m tools.reservoir_copy --execute  # copy the missing blobs, then verify
"""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Iterable
from dataclasses import replace
from datetime import UTC, date, datetime, timedelta
from typing import NamedTuple

from cc_otel_sink.config import load_settings

from ._progress import Progress
from ._reservoir import CurationReservoir
from ._window import partition_days, partition_prefix
from .signals import ROUTES

# ADR-0020's window floor, as `tools.cutover_copy.FLOOR` fixes it for the raw half: interim's
# own live telemetry effectively begins here, and pre-floor blobs die with the interim RG.
FLOOR = date(2026, 7, 17)

# ADR-0021's write-quiet window, the same 24h `tools.cutover_copy --sweep` waits on and for the
# same reason: interim's right edge must have stopped moving before a partition listing can settle.
# The *clock* differs because the store does -- `--sweep` reads `meta.processed_batches`, this reads
# the newest blob name -- so each store answers for itself (CONTEXT.md *write-quiet*). Deliberately
# no `--force` twin: copying early is a decision about permanent data placement, and the failure
# mode is a verification that passes over a window that then grows.
WRITE_QUIET_WINDOW = timedelta(hours=24)


class Counts(NamedTuple):
    """Blobs copied and their total compressed bytes."""

    blobs: int
    bytes_copied: int


class Partition(NamedTuple):
    """One ``(signal, day)`` partition: interim's blob names, and which of them production lacks."""

    signal: str
    day: date
    source_names: tuple[str, ...]
    missing: tuple[str, ...]
    target_total: int

    @property
    def source_total(self) -> int:
        return len(self.source_names)


def _write_time(name: str) -> datetime | None:
    """The blob's ingest wall-clock UTC, read off its own name, or ``None`` if unparseable.

    ``blob.py`` names every blob ``signal=<sig>/dt=<day>/<HHMMSS>-<uuid4>.json.gz`` from the
    sink's UTC clock at write, so the name *is* the write timestamp -- no ``last_modified``
    round trip, and a plain listing answers "when did this container last gain a blob".
    """
    parts = name.split("/")
    if len(parts) < 3 or not parts[1].startswith("dt="):
        return None
    try:
        day = date.fromisoformat(parts[1].removeprefix("dt="))
        clock = datetime.strptime(parts[-1].split("-", 1)[0], "%H%M%S").time()
    except ValueError:
        return None
    return datetime.combine(day, clock, tzinfo=UTC)


def newest_write(names: Iterable[str]) -> datetime | None:
    """Ingest wall-clock of the newest blob in ``names``; ``None`` if none can be read.

    Feeds the write-quiet gate, so an unreadable name is named on stderr and skipped rather
    than swallowed: counting it as "no write" would make the gate read quiet on exactly the
    input that deserves a human look.
    """
    stamps = []
    for name in names:
        stamped = _write_time(name)
        if stamped is None:
            print(f"skipping unparseable blob name {name!r}", file=sys.stderr)
            continue
        stamps.append(stamped)
    return max(stamps, default=None)


def plan(
    source: CurationReservoir, target: CurationReservoir, signals: tuple[str, ...]
) -> list[Partition]:
    """Every source partition from :data:`FLOOR` up, carrying the blob names production lacks.

    Discovered from the *source*, so production's own partitions outside the window are never
    considered. Set difference on blob **names** is exact rather than a count comparison:
    ``blob.py`` names carry a ``uuid4()``, so a name identifies one blob globally and the two
    sinks that write into the same post-repoint partition (ADR-0021) cannot collide. That also
    makes the copy re-runnable -- a name already in production is never a target again.
    """
    partitions = []
    for signal in signals:
        for day in partition_days(source.list_prefixes(f"signal={signal}/")):
            if day < FLOOR:
                continue
            # Listed per partition, not once per signal: production keeps growing past this
            # window, and a signal-wide listing would page through every day it has ever held to
            # answer a question about 18 of them. Same reason `verify` lists per partition.
            prefix = partition_prefix(signal, day)
            source_names = sorted(source.list_names(prefix))
            in_target = set(target.list_names(prefix))
            partitions.append(
                Partition(
                    signal,
                    day,
                    tuple(source_names),
                    tuple(name for name in source_names if name not in in_target),
                    len(in_target),
                )
            )
    return partitions


def copy(
    source: CurationReservoir, target: CurationReservoir, partitions: list[Partition]
) -> Counts:
    """Download each missing blob from ``source`` and upload it to ``target`` under the same name.

    Client-side rather than a server-side ``start_copy_from_url``: the payloads are gzipped
    OTLP batches averaging ~3 KB, so the whole window moves in tens of MB, and a cross-account
    server-side copy would need a source SAS or a copy-source authorization header -- a second
    auth path for no gain at this size. Interim is only ever read.
    """
    copied = written = 0
    progress = Progress("copy blobs", total=sum(len(p.missing) for p in partitions))
    for partition in partitions:
        for name in partition.missing:
            data = source.download(name)
            target.overwrite(name, data)
            copied += 1
            written += len(data)
            progress.tick()
    progress.done()
    return Counts(copied, written)


def verify(
    source: CurationReservoir, target: CurationReservoir, partitions: list[Partition]
) -> list[str]:
    """Per partition, the failure message if production lacks any of the source's blob names.

    Re-listed from both containers rather than asserted against the run's own bookkeeping: an
    upload the SDK accepted but the container did not keep has to fail the run. Containment,
    not equality -- production's own post-repoint blobs live in the same partitions (ADR-0021).
    """
    failures = []
    for partition in partitions:
        prefix = partition_prefix(partition.signal, partition.day)
        absent = sorted(set(source.list_names(prefix)) - set(target.list_names(prefix)))
        if absent:
            failures.append(
                f"Verification FAILED {partition.signal} {partition.day:%Y-%m-%d}:"
                f" {len(absent)} blob(s) missing in production, first {absent[0]}"
            )
    return failures


def open_end(account_url: str, container: str) -> CurationReservoir:
    """One environment's reservoir container, addressed by account URL under Entra auth.

    Account URL only, deliberately: a connection string names a single account and this tool
    needs two at once, so an ambient ``CC_OTEL_BLOB_CONNECTION_STRING`` must not silently decide
    either end. ``az login`` as an identity holding the roles in ``tools/README.md``.
    """
    settings = replace(
        load_settings(),
        blob_account_url=account_url,
        blob_connection_string=None,
        blob_container=container,
    )
    return CurationReservoir.from_settings(settings)


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--source-url", help="interim account URL; default $INTERIM_BLOB_ACCOUNT_URL")
    p.add_argument("--target-url", help="production account URL; default $PROD_BLOB_ACCOUNT_URL")
    p.add_argument("--execute", action="store_true", help="copy the blobs (default: dry-run)")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    source_url = args.source_url or os.environ.get("INTERIM_BLOB_ACCOUNT_URL")
    target_url = args.target_url or os.environ.get("PROD_BLOB_ACCOUNT_URL")
    # One container name for both ends -- ADR-0020's "same paths" includes the container, and both
    # environments provision it as `raw` (iac/modules/storage.bicep).
    container = os.environ.get("CC_OTEL_BLOB_CONTAINER", "raw")
    if not source_url or not target_url:
        print(
            "Need both accounts: pass --source-url/--target-url or set"
            " INTERIM_BLOB_ACCOUNT_URL/PROD_BLOB_ACCOUNT_URL",
            file=sys.stderr,
        )
        return 2
    # Named before anything else, as `tools.cutover_copy` names its two databases: the account
    # URLs differ by a few characters, and a swapped pair would copy production's live blobs back
    # into interim, which is due to be deleted.
    print(f"Source (interim):    {source_url} container={container}")
    print(f"Target (production): {target_url} container={container}")
    if source_url == target_url:
        print(
            f"Refused: source and target are the same container ({source_url} {container})"
            " — nothing copied",
            file=sys.stderr,
        )
        return 1

    source = open_end(source_url, container)
    target = open_end(target_url, container)
    try:
        partitions = plan(source, target, ROUTES)
        for partition in partitions:
            print(
                f"  {partition.signal:<8} {partition.day:%Y-%m-%d}  {len(partition.missing)}"
                f" missing of {partition.source_total} interim blob(s); production holds"
                f" {partition.target_total}"
            )
        to_copy = sum(len(p.missing) for p in partitions)
        newest = newest_write(name for p in partitions for name in p.source_names)
        age = None if newest is None else datetime.now(UTC) - newest
        print(
            "Interim write-quiet check: "
            + ("no blob in the window" if age is None else f"newest interim blob {age} ago")
        )

        if not to_copy:
            print(
                f"Production holds every interim blob from {FLOOR:%Y-%m-%d} up"
                f" — {len(partitions)} partition(s) verified"
            )
            return 0
        if not args.execute:
            print(f"Dry-run — nothing written; pass --execute to copy {to_copy} blob(s)")
            return 0
        if age is None or age < WRITE_QUIET_WINDOW:
            detail = (
                "no blob name in the window could be read"
                if age is None
                else f"newest blob {age} ago, under the {WRITE_QUIET_WINDOW} required"
            )
            print(
                f"Refused: interim is not write-quiet ({detail}) — its right edge is still"
                " moving, so a partition listing cannot settle; nothing written",
                file=sys.stderr,
            )
            return 1

        counts = copy(source, target, partitions)
        print(
            f"Reservoir copy -> production: copied {counts.blobs} blob(s),"
            f" {counts.bytes_copied / 1e6:.2f} MB"
        )
        # Verification follows the copy rather than gating it: blob writes have no transaction to
        # roll back, and a re-run is the repair -- a name already in production is never a target
        # again, so a short copy costs a second run, not a permanent gap.
        failures = verify(source, target, partitions)
        if failures:
            for line in failures:
                print(line, file=sys.stderr)
            print(
                "Copy incomplete — production keeps what did land and interim is untouched;"
                " re-run once the cause is understood",
                file=sys.stderr,
            )
            return 1
        print(f"Verified: production holds every interim blob in {len(partitions)} partition(s)")
        print(
            "Next: run `uv run python -m tools.compact --execute` against production — the days"
            " this copy touched need their parquet counterpart built, `--rebuild` for any day"
            " production had already compacted (ADR-0015)"
        )
        return 0
    finally:
        source.close()
        target.close()


if __name__ == "__main__":
    sys.exit(main())
