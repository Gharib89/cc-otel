"""Throttled stderr progress for the long blob loops in sweep / scrub / replay.

The curation tools stream over potentially thousands of blobs with no feedback until
they finish, so a long run looks hung. ``Progress`` emits a periodic ``label: n[/total]``
line — at most one per ``interval`` seconds, plus a final line on ``done()`` — to
**stderr only**, so a piped stdout report stays clean.
"""

from __future__ import annotations

import sys
import time
from typing import TextIO


class Progress:
    def __init__(
        self,
        label: str,
        *,
        total: int | None = None,
        interval: float = 2.0,
        stream: TextIO | None = None,
    ) -> None:
        self._label = label
        self._total = total
        self._interval = interval
        self._stream = stream if stream is not None else sys.stderr
        self._count = 0
        self._emitted = 0
        self._last = 0.0  # monotonic clock of the last emit; 0 forces an emit on the first tick

    def tick(self, n: int = 1) -> None:
        self._count += n
        now = time.monotonic()
        if now - self._last >= self._interval:
            self._emit()
            self._last = now

    def done(self) -> None:
        """Emit a final line unless the current count was already the last one shown."""
        if self._count and self._count != self._emitted:
            self._emit()

    def _emit(self) -> None:
        total = f"/{self._total}" if self._total is not None else ""
        print(f"{self._label}: {self._count}{total}", file=self._stream, flush=True)
        self._emitted = self._count
