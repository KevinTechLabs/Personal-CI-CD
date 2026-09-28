import pytest

from app.processing import MAX_PAYLOAD_CHARS, TaskError, process_payload


def test_process_payload_counts_words():
    result = process_payload("Hello hello world")
    assert result["words"] == 3
    assert result["unique_words"] == 2
    assert result["characters"] == 17
    assert len(result["sha256"]) == 64


def test_process_payload_is_deterministic():
    assert process_payload("same input") == process_payload("same input")


@pytest.mark.parametrize("payload", ["", "   ", "x" * (MAX_PAYLOAD_CHARS + 1)])
def test_process_payload_rejects_invalid(payload):
    with pytest.raises(TaskError):
        process_payload(payload)
