"""
Tests for the /ws/hazards on-demand voice query path
(server._handle_hazards_message()), which replaced the old POST /query
endpoint. Confirms:
- a well-formed {"question", "session_id"} message gets answered and the
  answer is sent back on the SAME connection, in {"answer": "..."} shape
- anything that isn't that shape (bad JSON, missing fields, unrelated
  traffic) is silently ignored, preserving the original
  disconnect-detection-only behavior for non-query traffic
- a failure anywhere in the query pipeline still replies with the fallback
  answer rather than raising

Uses asyncio.run() directly (matching the convention already used in
test_narration_worker.py) rather than adding a pytest-asyncio dependency.
A plain placeholder object stands in for the WebSocket, since
manager.send_to() is monkeypatched to record calls instead of touching a
real socket.
"""

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline import server


class FakeWebSocket:
    """Identity placeholder -- never actually sent to; just needs to be
    something send_to() can be called with and compared by identity."""


def _patch_dependencies(monkeypatch):
    sent = []

    async def fake_send_to(websocket, message):
        sent.append((websocket, message))

    async def fake_get_recent_context(session_id, limit=5):
        return [{"question": "prior question", "answer": "prior answer"}]

    async def fake_save_exchange(session_id, question, answer):
        pass

    async def fake_answer_query(frame, question, recent_context):
        return f"answer to: {question}"

    monkeypatch.setattr(server.manager, "send_to", fake_send_to)
    monkeypatch.setattr(server.conversation_memory, "get_recent_context", fake_get_recent_context)
    monkeypatch.setattr(server.conversation_memory, "save_exchange", fake_save_exchange)
    monkeypatch.setattr(server, "answer_query", fake_answer_query)
    monkeypatch.setattr(server, "capture_frame", lambda: b"fake-jpeg-bytes")

    return sent


def test_valid_query_gets_answered_on_the_same_connection(monkeypatch):
    sent = _patch_dependencies(monkeypatch)
    ws = FakeWebSocket()

    asyncio.run(
        server._handle_hazards_message(
            ws, '{"question": "what is ahead?", "session_id": "s1"}'
        )
    )

    assert len(sent) == 1
    replied_ws, message = sent[0]
    assert replied_ws is ws
    assert message == {"answer": "answer to: what is ahead?"}


def test_non_json_text_is_silently_ignored(monkeypatch):
    sent = _patch_dependencies(monkeypatch)
    asyncio.run(server._handle_hazards_message(FakeWebSocket(), "not json at all"))
    assert sent == []


def test_json_missing_required_fields_is_silently_ignored(monkeypatch):
    sent = _patch_dependencies(monkeypatch)
    ws = FakeWebSocket()

    asyncio.run(server._handle_hazards_message(ws, '{"foo": "bar"}'))
    asyncio.run(server._handle_hazards_message(ws, '{"question": "x"}'))  # no session_id
    asyncio.run(server._handle_hazards_message(ws, '{"session_id": "s1"}'))  # no question
    asyncio.run(server._handle_hazards_message(ws, '{"question": 5, "session_id": "s1"}'))  # wrong type

    assert sent == []


def test_query_failure_replies_with_fallback_instead_of_raising(monkeypatch):
    sent = _patch_dependencies(monkeypatch)

    async def failing_answer_query(frame, question, recent_context):
        raise RuntimeError("simulated failure")

    monkeypatch.setattr(server, "answer_query", failing_answer_query)
    ws = FakeWebSocket()

    asyncio.run(
        server._handle_hazards_message(ws, '{"question": "x", "session_id": "s1"}')
    )

    assert len(sent) == 1
    _, message = sent[0]
    assert message == {"answer": server._VOICE_QUERY_FALLBACK_ANSWER}


def test_conversation_memory_failure_also_falls_back(monkeypatch):
    sent = _patch_dependencies(monkeypatch)

    async def failing_get_recent_context(session_id, limit=5):
        raise RuntimeError("mongo unavailable")

    monkeypatch.setattr(server.conversation_memory, "get_recent_context", failing_get_recent_context)
    ws = FakeWebSocket()

    asyncio.run(
        server._handle_hazards_message(ws, '{"question": "x", "session_id": "s1"}')
    )

    assert len(sent) == 1
    _, message = sent[0]
    assert message == {"answer": server._VOICE_QUERY_FALLBACK_ANSWER}
