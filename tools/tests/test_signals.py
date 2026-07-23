import dataclasses

import pytest

from tools.signals import SIGNALS, Signal


def test_signals_are_the_two_frozen_records():
    assert SIGNALS == (
        Signal("metrics", "metrics", "metrics", "ts", "metric_name", "/v1/metrics"),
        Signal("logs", "events", "events", "event_time", "event_name", "/v1/logs"),
    )


def test_route_and_registry_name_diverge_for_logs():
    logs = next(s for s in SIGNALS if s.route == "logs")
    assert logs.registry_name == "events"
    assert logs.raw_table == "events"


def test_signal_is_frozen():
    with pytest.raises(dataclasses.FrozenInstanceError):
        SIGNALS[0].route = "other"  # type: ignore[misc]
