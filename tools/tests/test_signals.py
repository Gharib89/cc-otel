import dataclasses

import pytest

from tools.signals import BY_ROUTE, ROUTES, SIGNALS, Signal


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


def test_routes_are_the_signal_route_names_in_table_order():
    assert ROUTES == ("metrics", "logs")


def test_by_route_maps_each_route_to_its_record():
    assert set(BY_ROUTE) == set(ROUTES)
    assert BY_ROUTE["logs"] is next(s for s in SIGNALS if s.route == "logs")
    assert BY_ROUTE["metrics"].ingest_path == "/v1/metrics"
