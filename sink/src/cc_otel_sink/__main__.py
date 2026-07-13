"""Console entrypoint: serve the sink on the configured localhost port (#6)."""

from __future__ import annotations

import uvicorn

from .app import app
from .config import load_settings


def main() -> None:
    settings = load_settings()
    uvicorn.run(app, host=settings.host, port=settings.port)


if __name__ == "__main__":
    main()
