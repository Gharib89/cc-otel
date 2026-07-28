from cc_otel_sink.config import load_settings


def test_compacted_container_unset_is_none(monkeypatch):
    # ADR-0015: unset means the analysis read path behaves exactly as it did before
    # compaction existed, so a machine that never compacted anything still runs.
    monkeypatch.delenv("CC_OTEL_BLOB_COMPACTED_CONTAINER", raising=False)
    assert load_settings().blob_compacted_container is None


def test_compacted_container_reads_the_environment(monkeypatch):
    monkeypatch.setenv("CC_OTEL_BLOB_COMPACTED_CONTAINER", "compacted")
    assert load_settings().blob_compacted_container == "compacted"
