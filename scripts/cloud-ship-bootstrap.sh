#!/usr/bin/env bash
# Per-fire sandbox bootstrap for the cloud-ship routine.
#
# Syncs the uv workspace and probes for a Docker daemon. The DOCKER= line is
# consumed by the cloud-ship skill: `present` means testcontainers integration
# tests (and dbmate schema.sql regeneration against a throwaway Postgres) can
# run inside the fire; `absent` means PR CI is the integration gate and
# schema-touching issues are blocked.
set -euo pipefail

cd "$(dirname "$0")/.."

uv sync --frozen

if docker info >/dev/null 2>&1; then
    echo "DOCKER=present"
else
    echo "DOCKER=absent"
fi
