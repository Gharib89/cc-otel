-- migrate:up

-- The curated catalogue of every promoted column and known OTLP attribute (#16).
-- Per-signal-name grain: the same attr under different signal names gets its own row,
-- because semantics differ (e.g. duration_ms). Standard/identity attrs and resource-block
-- attrs are recorded once with signal_name = '*'. Three-state status IS the redaction
-- classification: promoted (typed column), kept (blob-only), denied (sink strips; never at
-- rest). Rows are maintained as migration data alongside the DDL so the registry can't
-- drift from the schema.

CREATE TABLE meta.column_registry (
    signal TEXT NOT NULL,   -- 'metrics' | 'events' | 'resource'
    signal_name TEXT NOT NULL,   -- event/metric name; '*' for standard/resource attrs
    attr_path TEXT NOT NULL,   -- key path in the OTLP payload
    status TEXT NOT NULL,   -- 'promoted' | 'kept' | 'denied'
    column_name TEXT,            -- raw-table column when promoted
    data_type TEXT,            -- SQL type when promoted
    description TEXT,
    useful_for TEXT,            -- feeds the generated data dictionary
    decided_at DATE,
    notes TEXT,            -- backfill decision, exposure window, issue/PR links
    PRIMARY KEY (signal, signal_name, attr_path),
    CONSTRAINT column_registry_signal_chk CHECK (signal IN ('metrics', 'events', 'resource')),
    CONSTRAINT column_registry_status_chk CHECK (status IN ('promoted', 'kept', 'denied')),
    -- promoted rows carry a column mapping; kept/denied never do.
    CONSTRAINT column_registry_promoted_chk CHECK (
        (status = 'promoted' AND column_name IS NOT NULL AND data_type IS NOT NULL)
        OR (status <> 'promoted' AND column_name IS NULL AND data_type IS NULL)
    )
);

GRANT SELECT ON meta.column_registry TO cc_otel_ingest, cc_otel_read;

-- migrate:down

DROP TABLE IF EXISTS meta.column_registry;
