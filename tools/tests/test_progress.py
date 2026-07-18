import io

from tools._progress import Progress


def test_ticks_emit_to_the_given_stream_with_count_and_total():
    buf = io.StringIO()
    p = Progress("sweep", total=3, interval=0.0, stream=buf)
    p.tick()
    p.tick()
    assert buf.getvalue().splitlines() == ["sweep: 1/3", "sweep: 2/3"]


def test_total_is_omitted_when_unknown():
    buf = io.StringIO()
    p = Progress("scrub", interval=0.0, stream=buf)
    p.tick()
    assert buf.getvalue().strip() == "scrub: 1"


def test_interval_throttles_intermediate_ticks():
    buf = io.StringIO()
    # A large interval suppresses every tick after the first until done() flushes the tail.
    p = Progress("replay", total=100, interval=3600.0, stream=buf)
    for _ in range(50):
        p.tick()
    assert buf.getvalue() == "replay: 1/100\n"
    p.done()
    assert buf.getvalue().splitlines()[-1] == "replay: 50/100"


def test_done_is_silent_when_nothing_ticked():
    buf = io.StringIO()
    Progress("sweep", interval=0.0, stream=buf).done()
    assert buf.getvalue() == ""
