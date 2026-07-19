"""
Tests for camera_events.py's CameraEventBridge: proves the thread-to-asyncio
bridge actually works (an event fired from a real separate thread safely
appears in the consuming asyncio queue), and that malformed events are
dropped rather than queued or crashing anything.

Uses asyncio.run() directly (matching the convention already used
elsewhere in this suite) rather than adding a pytest-asyncio dependency.
listen_events() itself (the real UDP socket listener) is not exercised
here -- these tests call CameraEventBridge._on_event() directly, which is
exactly what her callback invokes per event; that's the actual boundary
this bridge needs to prove safe, without needing a real socket.
"""

import asyncio
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline.camera_events import CameraEventBridge, is_valid_detection


def _valid_detection(direction: str = "left") -> dict:
    return {"timestamp": 0, "object_class": "person", "direction": direction, "confidence": 0.9}


def test_is_valid_detection_accepts_well_formed_events():
    assert is_valid_detection(_valid_detection("left")) is True
    assert is_valid_detection(_valid_detection("center")) is True
    assert is_valid_detection(_valid_detection("right")) is True


def test_is_valid_detection_rejects_malformed_events():
    assert is_valid_detection("not a dict") is False
    assert is_valid_detection(123) is False
    assert is_valid_detection(None) is False
    assert is_valid_detection({"object_class": "person", "direction": "left", "confidence": 0.9}) is False  # missing timestamp
    assert is_valid_detection({"timestamp": 0, "direction": "left", "confidence": 0.9}) is False  # missing object_class
    assert is_valid_detection({**_valid_detection(), "direction": "up"}) is False  # invalid direction
    assert is_valid_detection({**_valid_detection(), "direction": "sideways"}) is False


def test_bridge_receives_event_fired_from_a_real_separate_thread():
    """
    This is the actual thing that needs proving: listen_events()'s callback
    fires on ITS OWN background thread, not the event loop's thread.
    _on_event() must get that event into the asyncio queue safely (via
    call_soon_threadsafe(), not a direct, thread-unsafe queue touch) --
    proven here with a real threading.Thread, not just a same-thread call.
    """
    async def run():
        bridge = CameraEventBridge()
        detection = _valid_detection()

        def fire_from_thread():
            bridge._on_event(detection)

        thread = threading.Thread(target=fire_from_thread)
        thread.start()
        thread.join()

        # thread.join() only confirms the call_soon_threadsafe() scheduling
        # completed -- the scheduled _push() itself only runs once we hand
        # control back to the event loop, which awaiting the stream does.
        stream = bridge.stream()
        return await asyncio.wait_for(stream.__anext__(), timeout=2.0)

    result = asyncio.run(run())
    assert result == _valid_detection()


def test_malformed_events_are_dropped_never_reaching_the_queue():
    async def run():
        bridge = CameraEventBridge()

        bad_events = [
            {"object_class": "person", "direction": "left", "confidence": 0.9},  # missing timestamp
            {**_valid_detection(), "direction": "up"},  # invalid direction for a camera event
            "not a dict",
            123,
            None,
        ]
        for event in bad_events:
            bridge._on_event(event)

        # One valid event, pushed last. If any malformed event had made it
        # onto the (FIFO) queue, it would come out first instead of this one.
        good = _valid_detection("right")
        bridge._on_event(good)

        result = await asyncio.wait_for(bridge.stream().__anext__(), timeout=2.0)
        # Confirms none of the 5 malformed events snuck onto the queue
        # too -- if they had, the queue wouldn't be empty now.
        queue_size_after = bridge._queue.qsize()
        return result, queue_size_after

    result, queue_size_after = asyncio.run(run())
    assert result == _valid_detection("right")
    assert queue_size_after == 0
