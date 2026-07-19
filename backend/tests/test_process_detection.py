"""
Tests for main.py's _process_detection() -- the actual capture_frame()
call site in the current architecture (frames are captured before being
queued, not inside narration_worker.py, despite an earlier task
description assuming otherwise -- see README/memory notes). Confirms a
None frame (capture failure) skips the narration_queue push entirely,
logs clearly, and doesn't prevent later detections from being processed
normally.

Uses asyncio.run() directly, matching the convention used elsewhere in
this suite.
"""

import asyncio
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline import main


def _detection() -> dict:
    return {
        "timestamp": 0,
        "object_class": "person",
        "direction": "center",
        "confidence": 0.9,
        "distance_m": 1.0,
    }


def _patch(monkeypatch, *, escalate: bool = True, frame=b"fake-jpeg"):
    pushed = []

    async def fake_attach_distance(detection):
        return detection

    def fake_should_escalate(detection):
        return escalate

    async def fake_capture_frame():
        return frame

    def fake_push_nowait(event):
        pushed.append(event)

    monkeypatch.setattr(main, "attach_distance", fake_attach_distance)
    monkeypatch.setattr(main, "should_escalate", fake_should_escalate)
    monkeypatch.setattr(main, "capture_frame", fake_capture_frame)
    monkeypatch.setattr(main.narration_queue, "push_nowait", fake_push_nowait)

    return pushed


def test_successful_frame_capture_pushes_event(monkeypatch):
    pushed = _patch(monkeypatch, frame=b"real-frame-bytes")

    asyncio.run(main._process_detection(_detection()))

    assert len(pushed) == 1
    assert pushed[0]["source"] == "camera"
    assert pushed[0]["frame"] == b"real-frame-bytes"


def test_none_frame_skips_the_push_entirely_and_logs(monkeypatch, caplog):
    pushed = _patch(monkeypatch, frame=None)

    with caplog.at_level(logging.WARNING):
        asyncio.run(main._process_detection(_detection()))

    assert pushed == []
    assert "Frame capture failed" in caplog.text


def test_processing_continues_normally_after_a_none_frame(monkeypatch):
    # A None frame for one detection must not leave anything broken --
    # the very next detection, with a successful capture, must still go
    # through normally.
    pushed = _patch(monkeypatch, frame=None)
    asyncio.run(main._process_detection(_detection()))
    assert pushed == []

    async def fake_capture_frame_ok():
        return b"second-frame-bytes"

    monkeypatch.setattr(main, "capture_frame", fake_capture_frame_ok)
    asyncio.run(main._process_detection(_detection()))

    assert len(pushed) == 1
    assert pushed[0]["frame"] == b"second-frame-bytes"


def test_unescalated_detection_never_calls_capture_frame(monkeypatch):
    calls = {"count": 0}

    async def counting_capture_frame():
        calls["count"] += 1
        return b"frame"

    pushed = _patch(monkeypatch, escalate=False)
    monkeypatch.setattr(main, "capture_frame", counting_capture_frame)

    asyncio.run(main._process_detection(_detection()))

    assert calls["count"] == 0
    assert pushed == []
