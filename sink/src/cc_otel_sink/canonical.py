"""Canonical serialization of a (redacted) OTLP payload.

The single source of the byte form used for both the idempotency hash and the blob
reservoir content. The curation tools (``tools.scrub`` / ``tools.replay``) depend on this
exact form to keep scrubbed/replayed blobs byte-identical and hash-matching (#7/#8), so it
must live in one place — never re-inline ``json.dumps`` with these options elsewhere.
"""

from __future__ import annotations

import json
from typing import Any


def canonical_bytes(payload: dict[str, Any]) -> bytes:
    return json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
