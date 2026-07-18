"""
Mock camera heartbeat input: a periodic signal independent of detection
events, meant to be pushed by the camera process on a fixed interval
regardless of whether anything was detected. This is what lets the system
tell "camera saw nothing hazardous" apart from "camera pipeline died" --
should_escalate() returning False looks identical to a dead camera from
the narration/haptic paths' point of view, since neither of those paths
has any notion of "the camera should have said something by now."

INTEGRATION POINT (real hardware): mock_heartbeat_stream() stands in for
the real camera process's heartbeat feed. Swap it for an async generator
reading off the real hardware's heartbeat channel, yielding dicts with the
same shape -- {"status": "ok"|"error", "timestamp": ...} -- and point
status_loop.py at it instead.
"""

from __future__ import annotations

import asyncio
import time
from typing import AsyncIterator

HEARTBEAT_INTERVAL_SECONDS = 5.0

# Simulated-failure state. Module-level and simple by design -- this is a
# test/demo control surface, not part of the real contract, so it doesn't
# need the concurrency-safety care tof_input.py's real sensor mock does.
_silent_until: float = 0.0
_emit_error_once: bool = False


def simulate_camera_failure(duration_s: float = 20.0) -> None:
    """
    Test/demo control: makes mock_heartbeat_stream() stop yielding
    anything at all for duration_s seconds, simulating a real camera
    process crash (silence, not an explicit error report) -- the harder
    failure mode to detect, and the one CameraWatchdog's timeout exists
    for. Call this while the server is running (e.g. from a REPL, a test,
    or a future debug endpoint) to exercise that path.
    """
    global _silent_until
    _silent_until = time.monotonic() + duration_s


def simulate_camera_error() -> None:
    """
    Test/demo control: makes the next heartbeat yielded be
    {"status": "error", ...} instead of {"status": "ok", ...}, then
    reverts to normal -- for testing the "camera explicitly reports a
    problem" path separately from pure silence.
    """
    global _emit_error_once
    _emit_error_once = True


async def mock_heartbeat_stream() -> AsyncIterator[dict]:
    """
    Yields {"status": "ok", "timestamp": ...} every HEARTBEAT_INTERVAL_SECONDS,
    or {"status": "error", "timestamp": ...} once if simulate_camera_error()
    was called, or nothing at all (real silence, no messages -- not even
    error ones) while a simulate_camera_failure() window is active.
    """
    global _emit_error_once

    while True:
        await asyncio.sleep(HEARTBEAT_INTERVAL_SECONDS)

        if time.monotonic() < _silent_until:
            # Simulated crash: genuinely yield nothing this cycle, exactly
            # like a dead process would produce no output at all.
            continue

        if _emit_error_once:
            _emit_error_once = False
            yield {"status": "error", "timestamp": time.time()}
        else:
            yield {"status": "ok", "timestamp": time.time()}
