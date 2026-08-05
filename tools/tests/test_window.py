from datetime import date

import pytest

from tools._window import (
    compacted_url,
    date_range,
    globs,
    partition_days,
    partition_glob,
    prefixes,
    resolve_window,
)


def test_partition_days_parses_dt_prefixes():
    assert partition_days(["signal=logs/dt=2026-07-27/", "signal=logs/dt=2026-07-26/"]) == [
        date(2026, 7, 26),
        date(2026, 7, 27),
    ]  # ascending, so catch-up runs oldest first


def test_partition_days_ignores_children_that_are_not_partitions():
    assert partition_days(["signal=logs/dt=2026-07-26/", "signal=logs/other/"]) == [
        date(2026, 7, 26)
    ]


def test_partition_days_skips_an_unparseable_dt_without_aborting(capsys):
    # One stray prefix must not abort discovery of every other partition — what skipping costs
    # is the caller's: a lost speedup for compact, an uncopied partition for reservoir_copy.
    assert partition_days(["signal=logs/dt=not-a-date/", "signal=logs/dt=2026-07-26/"]) == [
        date(2026, 7, 26)
    ]
    assert "dt=not-a-date" in capsys.readouterr().err  # named, not silently swallowed


def test_date_range_is_inclusive():
    assert date_range(date(2026, 7, 10), date(2026, 7, 12)) == [
        date(2026, 7, 10),
        date(2026, 7, 11),
        date(2026, 7, 12),
    ]


def test_date_range_rejects_reversed_window():
    with pytest.raises(ValueError):
        date_range(date(2026, 7, 12), date(2026, 7, 10))


def test_resolve_window_defaults_days_back_from_today():
    today = date(2026, 7, 16)
    assert resolve_window(3, None, None, today) == [
        date(2026, 7, 14),
        date(2026, 7, 15),
        date(2026, 7, 16),
    ]


def test_resolve_window_explicit_dates_override_days():
    today = date(2026, 7, 16)
    assert resolve_window(30, date(2026, 7, 1), date(2026, 7, 2), today) == [
        date(2026, 7, 1),
        date(2026, 7, 2),
    ]


def test_prefixes_and_globs_cover_signal_x_day():
    days = [date(2026, 7, 10)]
    assert prefixes(("metrics", "logs"), days) == [
        "signal=metrics/dt=2026-07-10/",
        "signal=logs/dt=2026-07-10/",
    ]
    assert globs("raw", ("metrics",), days) == [
        "azure://raw/signal=metrics/dt=2026-07-10/*.json.gz",
    ]


def test_globs_is_the_partition_glob_cross_product():
    days = [date(2026, 7, 10)]
    assert globs("raw", ("metrics", "logs"), days) == [
        partition_glob("raw", "metrics", days[0]),
        partition_glob("raw", "logs", days[0]),
    ]


def test_compacted_url_mirrors_the_raw_partition_layout():
    # Same Hive prefix as raw, one deterministic file name, so the two stay symmetric.
    assert (
        compacted_url("compacted", "logs", date(2026, 7, 26))
        == "azure://compacted/signal=logs/dt=2026-07-26/part-0.parquet"
    )
