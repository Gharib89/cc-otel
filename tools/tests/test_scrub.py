import gzip
import json

from tools.scrub import canonical_bytes, rescrub


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
