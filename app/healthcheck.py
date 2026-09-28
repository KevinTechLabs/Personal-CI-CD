"""Container healthcheck helper (Alpine images have no curl).

Usage:
  python -m app.healthcheck http://127.0.0.1:8000/health
  python -m app.healthcheck --heartbeat /tmp/worker-heartbeat 30
"""

from __future__ import annotations

import sys
import time
import urllib.request
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "--heartbeat":
        max_age = float(argv[2]) if len(argv) > 2 else 30.0
        try:
            age = time.time() - Path(argv[1]).stat().st_mtime
        except FileNotFoundError:
            return 1
        return 0 if age < max_age else 1

    url = argv[0] if argv else "http://127.0.0.1:8000/health"
    if not url.startswith("http://127.0.0.1"):
        return 2  # only ever probe ourselves
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:  # noqa: S310  # nosec B310
            return 0 if resp.status == 200 else 1
    except Exception:  # noqa: BLE001
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
