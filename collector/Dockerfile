# Packages config.yaml into the pinned contrib image (issue #21). The base image
# is distroless and already runs /otelcol-contrib with --config at this path, so
# baking the config is all that's needed.
FROM otel/opentelemetry-collector-contrib:0.156.0
COPY config.yaml /etc/otelcol-contrib/config.yaml
