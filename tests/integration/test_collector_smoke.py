"""Collector compose smoke (issue #21).

Drives collector/docker-compose.smoke.yaml through the three acceptance
scenarios: a token-bearing OTLP request reaches the sink; a missing/wrong token
is rejected; a request sent while the sink is down is retained in the queue and
delivered once the sink recovers.

Slow (~3-4 min): the shipped config batches on a 60s timeout (ADR-0005), so
delivery assertions poll generously. Needs Docker + compose, like the DB
integration tests.
"""

from __future__ import annotations

import subprocess
import time
import uuid
from pathlib import Path

import httpx
import pytest

COLLECTOR_DIR = Path(__file__).resolve().parents[2] / "collector"
COMPOSE = ["docker", "compose", "-f", str(COLLECTOR_DIR / "docker-compose.smoke.yaml")]
RECEIVER = "http://127.0.0.1:4318/v1/logs"
TOKEN = "smoke-token"


def _compose(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run([*COMPOSE, *args], check=check, capture_output=True, text=True)


def _logs(service: str) -> str:
    return subprocess.run(
        [*COMPOSE, "logs", "--no-color", service], capture_output=True, text=True
    ).stdout


def _payload(marker: str) -> dict:
    return {
        "resourceLogs": [
            {
                "scopeLogs": [
                    {
                        "logRecords": [
                            {
                                "timeUnixNano": str(time.time_ns()),
                                "body": {"stringValue": marker},
                            }
                        ]
                    }
                ]
            }
        ]
    }


def _post(marker: str, token: str | None) -> httpx.Response:
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    return httpx.post(RECEIVER, json=_payload(marker), headers=headers, timeout=10)


def _wait_receiver(timeout: float = 90) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if _post("ping", token=None).status_code == 401:  # up and enforcing auth
                return
        except httpx.HTTPError:
            pass
        time.sleep(1)
    raise RuntimeError("collector receiver never came up")


def _wait_marker(service: str, marker: str, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if marker in _logs(service):
            return True
        time.sleep(2)
    return False


@pytest.fixture(scope="module")
def stack():
    _compose("up", "-d", "--build")
    try:
        _wait_receiver()
        yield
    finally:
        _compose("down", "-v", check=False)


def test_valid_token_reaches_sink(stack):
    marker = f"valid-{uuid.uuid4().hex}"
    assert _post(marker, token=TOKEN).status_code == 200
    assert _wait_marker("mocksink", marker, timeout=90), "valid-token record never reached sink"


def test_missing_and_wrong_token_rejected(stack):
    assert _post("nomarker", token=None).status_code == 401
    assert _post("nomarker", token="wrong-token").status_code == 401


def test_sink_down_request_retained_and_delivered_on_recovery(stack):
    _compose("stop", "mocksink")
    marker = f"queued-{uuid.uuid4().hex}"
    # Collector accepts and queues even though the sink is unreachable.
    assert _post(marker, token=TOKEN).status_code == 200
    time.sleep(5)  # let the batch flush and fail at least once against the down sink
    _compose("start", "mocksink")
    assert _wait_marker("mocksink", marker, timeout=120), (
        "queued record was not delivered after the sink recovered"
    )
