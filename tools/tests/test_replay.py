import gzip
import hashlib
from datetime import UTC, date, datetime

import pytest

from tools.replay import _bounds, blob_hash, endpoint_for


def test_blob_hash_is_sha256_of_decompressed_bytes():
    raw = b'{"resourceLogs":[]}'
    assert blob_hash(gzip.compress(raw)) == hashlib.sha256(raw).hexdigest()


@pytest.mark.parametrize(
    ("name", "path"),
    [
        ("signal=metrics/dt=2026-07-16/120000-abc.json.gz", "/v1/metrics"),
        ("signal=logs/dt=2026-07-16/120000-abc.json.gz", "/v1/logs"),
    ],
)
def test_endpoint_for_maps_partition_to_route(name, path):
    assert endpoint_for(name) == path


def test_bounds_is_half_open_utc_over_inclusive_dates():
    start, end = _bounds(date(2026, 7, 10), date(2026, 7, 11))
    assert start == datetime(2026, 7, 10, tzinfo=UTC)
    assert end == datetime(2026, 7, 12, tzinfo=UTC)
