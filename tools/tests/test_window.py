from datetime import date

import pytest

from tools._window import date_range, globs, prefixes


def test_date_range_is_inclusive():
    assert date_range(date(2026, 7, 10), date(2026, 7, 12)) == [
        date(2026, 7, 10),
        date(2026, 7, 11),
        date(2026, 7, 12),
    ]


def test_date_range_rejects_reversed_window():
    with pytest.raises(ValueError):
        date_range(date(2026, 7, 12), date(2026, 7, 10))


def test_prefixes_and_globs_cover_signal_x_day():
    days = [date(2026, 7, 10)]
    assert prefixes(("metrics", "logs"), days) == [
        "signal=metrics/dt=2026-07-10/",
        "signal=logs/dt=2026-07-10/",
    ]
    assert globs("raw", ("metrics",), days) == [
        "azure://raw/signal=metrics/dt=2026-07-10/*.json.gz",
    ]
