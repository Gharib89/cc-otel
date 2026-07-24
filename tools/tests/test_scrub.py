import gzip
import json
from datetime import date

from tools._window import partition_prefix
from tools.scrub import canonical_bytes, rescrub, run


def _blob(payload: dict) -> bytes:
    return gzip.compress(json.dumps(payload).encode())


def _logs(attrs: list[dict]) -> dict:
    return {"resourceLogs": [{"scopeLogs": [{"logRecords": [{"attributes": attrs}]}]}]}


def test_rescrub_strips_denied_key():
    payload = _logs(
        [
            {"key": "event.name", "value": {"stringValue": "tool_result"}},
            {"key": "file_path", "value": {"stringValue": "/etc/secret"}},
        ]
    )
    scrubbed, _ = rescrub(_blob(payload))
    out = json.loads(gzip.decompress(scrubbed))
    keys = [a["key"] for a in out["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]["attributes"]]
    assert "file_path" not in keys
    assert "event.name" in keys


def test_rescrub_counts_defense_in_depth_leak():
    payload = _logs(
        [
            {"key": "event.name", "value": {"stringValue": "api_request"}},
            {"key": "prompt", "value": {"stringValue": "secret prompt"}},
        ]
    )
    _, leaks = rescrub(_blob(payload))
    assert leaks == 1


def test_rescrub_is_idempotent_at_content_level():
    payload = _logs([{"key": "event.name", "value": {"stringValue": "api_request"}}])
    once, _ = rescrub(_blob(payload))
    twice, _ = rescrub(once)
    assert gzip.decompress(once) == gzip.decompress(twice)


def test_clean_blob_roundtrips_to_canonical_bytes():
    payload = _logs([{"key": "event.name", "value": {"stringValue": "api_request"}}])
    scrubbed, leaks = rescrub(_blob(payload))
    assert leaks == 0
    # a clean payload's scrubbed content is exactly its canonical serialization
    assert gzip.decompress(scrubbed) == canonical_bytes(payload)


# --- run() over a fake reservoir ------------------------------------------------

_DAY = date(2026, 7, 20)
_SIGNALS = ("logs",)


def _name(slug: str) -> str:
    return partition_prefix("logs", _DAY) + slug + ".json.gz"


def _dirty_blob() -> bytes:
    # a denied key present -> rescrub strips it, so scrubbed != original
    payload = _logs(
        [
            {"key": "event.name", "value": {"stringValue": "tool_result"}},
            {"key": "file_path", "value": {"stringValue": "/etc/secret"}},
        ]
    )
    return gzip.compress(json.dumps(payload).encode())


def _clean_blob() -> bytes:
    # already canonical -> rescrub is a byte-identical no-op, so run() skips the write
    payload = _logs([{"key": "event.name", "value": {"stringValue": "api_request"}}])
    return gzip.compress(canonical_bytes(payload))


def test_dry_run_performs_no_overwrites(fake_reservoir):
    res = fake_reservoir({_name("dirty"): _dirty_blob(), _name("clean"): _clean_blob()})
    counts = run(res, _SIGNALS, [_DAY], execute=False)
    assert res.overwrites == []  # dry-run writes nothing
    assert counts.scanned == 2
    assert counts.rewritten == 1  # the dirty blob would be rewritten; the clean one skipped


def test_execute_rewrites_only_dirty_blobs(fake_reservoir):
    dirty, clean = _name("dirty"), _name("clean")
    res = fake_reservoir({dirty: _dirty_blob(), clean: _clean_blob()})
    counts = run(res, _SIGNALS, [_DAY], execute=True)
    assert res.overwrites == [dirty]  # clean blob untouched
    assert counts.rewritten == 1


def test_execute_is_idempotent(fake_reservoir):
    res = fake_reservoir({_name("dirty"): _dirty_blob()})
    run(res, _SIGNALS, [_DAY], execute=True)
    res.overwrites.clear()
    counts = run(res, _SIGNALS, [_DAY], execute=True)  # second pass over the rewritten result
    assert res.overwrites == []
    assert counts.rewritten == 0


def test_defense_in_depth_leak_count_surfaces_in_counts(fake_reservoir):
    payload = _logs(
        [
            {"key": "event.name", "value": {"stringValue": "api_request"}},
            {"key": "prompt", "value": {"stringValue": "secret prompt"}},
        ]
    )
    res = fake_reservoir({_name("leaky"): gzip.compress(json.dumps(payload).encode())})
    counts = run(res, _SIGNALS, [_DAY], execute=False)
    assert counts.leaks == 1
