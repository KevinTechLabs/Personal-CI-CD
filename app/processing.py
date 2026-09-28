"""Task processing logic, kept free of I/O so it is easy to unit test."""

from __future__ import annotations

import hashlib

MAX_PAYLOAD_CHARS = 10_000


class TaskError(ValueError):
    """Raised for payloads that can never succeed (no retry)."""


def process_payload(payload: str) -> dict:
    if not payload.strip():
        raise TaskError("payload is empty")
    if len(payload) > MAX_PAYLOAD_CHARS:
        raise TaskError(f"payload exceeds {MAX_PAYLOAD_CHARS} characters")

    words = payload.split()
    return {
        "characters": len(payload),
        "words": len(words),
        "unique_words": len({w.lower() for w in words}),
        "sha256": hashlib.sha256(payload.encode("utf-8")).hexdigest(),
    }
