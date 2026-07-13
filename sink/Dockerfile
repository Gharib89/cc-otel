# Build context is sink/ (the workspace member is self-contained — its pyproject
# carries every runtime dep, no workspace root needed).
FROM python:3.13-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app
COPY pyproject.toml ./
COPY src ./src
RUN uv pip install --system --no-cache .

# localhost only — fronted by the collector in the same Container App, never its
# own external ingress (#6). Host/port come from the environment (config.py).
EXPOSE 8080
CMD ["python", "-m", "cc_otel_sink"]
