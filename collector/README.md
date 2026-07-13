# Collector

The OpenTelemetry Collector (contrib **v0.156.0**) — the fleet's only
authenticated ingest boundary. It receives OTLP/protobuf over HTTP, verifies the
fleet bearer token, converts to OTLP/JSON, and forwards to the co-located sink at
`127.0.0.1:8080`. No traces pipeline (ADR-0001).

| File | Role |
|---|---|
| `config.yaml` | Shipped collector config (baked into the image) |
| `Dockerfile` | Packages `config.yaml` into the pinned contrib image |
| `docker-compose.smoke.yaml` + `mocksink.smoke.yaml` | Local compose smoke harness (test-only) |

## `FLEET_TOKENS`

The `bearertokenauth` extension reads its accepted tokens from `${env:FLEET_TOKENS}`.
The collector env provider parses the value as YAML, so it **must be a YAML inline
list of strings**, not a bare comma-separated string:

```
FLEET_TOKENS=["tokenA","tokenB"]
```

Multiple tokens enable zero-loss overlap rotation (issue #6): add the new token
alongside the old, let the fleet converge, then drop the old one. Wiring from the
secret store to this env var is issue #11; the emptyDir volume backing the
persistent queue (`/var/lib/otelcol/sending-queue`) is defined in the Bicep of
issue #23.

## Reliability

Delivery to the sink uses a persistent `sending_queue` (backed by the
`file_storage` extension) with retry-forever (`max_elapsed_time: 0`), so an outage
or restart never drops data (issue #7).

## Smoke test

`tests/integration/test_collector_smoke.py` drives `docker-compose.smoke.yaml`
(needs Docker + compose) through all three acceptance scenarios. It's slow
(~3-4 min) because the shipped config batches on a 60s timeout (ADR-0005):

```sh
uv run pytest tests/integration/test_collector_smoke.py
```

To validate the config directly against the pinned image:

```sh
docker run --rm -e FLEET_TOKENS='["x"]' -v "$PWD/config.yaml:/cfg.yaml:ro" \
  otel/opentelemetry-collector-contrib:0.156.0 validate --config=/cfg.yaml
```
