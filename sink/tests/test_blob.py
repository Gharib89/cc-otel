"""Blob reservoir (ADR-0005): partition path, gzip, best-effort, clean close."""

from __future__ import annotations

import gzip

from cc_otel_sink.blob import BlobReservoir


class FakeContainer:
    def __init__(self, fail: bool = False) -> None:
        self.uploads: list[tuple[str, bytes]] = []
        self.closed = False
        self.fail = fail

    def upload_blob(self, name, data, overwrite=False):
        if self.fail:
            raise RuntimeError("network down")
        self.uploads.append((name, data))

    def close(self):
        self.closed = True


def test_write_uploads_gzipped_partitioned_blob():
    container = FakeContainer()
    BlobReservoir(container).write("metrics", b'{"resourceMetrics":[]}')
    (name, data) = container.uploads[0]
    assert name.startswith("signal=metrics/dt=")
    assert name.endswith(".json.gz")
    assert gzip.decompress(data) == b'{"resourceMetrics":[]}'


def test_write_is_best_effort_on_failure():
    container = FakeContainer(fail=True)
    # Must not raise — a blob failure never affects ingest.
    BlobReservoir(container).write("logs", b"{}")


def test_close_releases_container():
    container = FakeContainer()
    BlobReservoir(container).close()
    assert container.closed is True
