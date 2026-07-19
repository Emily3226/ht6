"""
Real camera detection events, provided by a teammate's board over UDP.

listen_events() below is her code, unmodified: it starts a daemon thread
listening on EVENT_PORT, calling a callback once per detection received.
That callback fires on HER background thread, not the asyncio event loop
this backend runs on -- CameraEventBridge exists to get those events
safely into async code the rest of the pipeline can consume with a plain
`async for detection in bridge.stream():`, matching mock_detection_stream()'s
shape.

This solves the same category of problem as tof_input.py's
asyncio.to_thread() wrapping -- blocking/thread-driven hardware I/O has to
be bridged into asyncio somehow -- but the shape is different:
read_all_tof() is one blocking call per poll, wrapped fresh each time.
listen_events() is a long-lived background thread that pushes events
whenever they arrive, so the bridge here is a thread-safe asyncio.Queue
fed via loop.call_soon_threadsafe(), not a per-call to_thread() wrapper.
asyncio.Queue itself is NOT thread-safe -- put_nowait() must only ever be
called from the event loop's own thread, which is exactly what
call_soon_threadsafe() schedules.
"""

from __future__ import annotations

import asyncio
import json
import logging
import socket
import threading
from typing import AsyncIterator, Callable

logger = logging.getLogger(__name__)

# Real hardware, provided by teammate -- same physical board as
# tof_input.py's ToF endpoint, different port. Hardcoded to match her code
# exactly (no env var), consistent with tof_input.py's BOARD_IP convention:
# this is specific to this physical board, not a per-deployment config value.
BOARD_IP = "172.20.10.2"
EVENT_PORT = 5005

_REQUIRED_KEYS = ("timestamp", "object_class", "direction", "confidence")
_VALID_DIRECTIONS = ("left", "center", "right")

# Generous, not a real backpressure mechanism -- same reasoning as
# narration_queue.py's cap. Detections arrive far slower than this could
# ever fill in practice; this only guards against a stalled consumer.
_MAX_QUEUE_SIZE = 1000


def listen_events(callback: Callable[[dict], None]) -> None:
    """
    Her code, unmodified: starts a daemon thread listening for detection
    events over UDP on EVENT_PORT, calling callback(dict) once per event.
    Note her own try/except around the callback swallows ANY exception it
    raises, silently -- which is exactly why CameraEventBridge._on_event()
    below must never itself raise; a bug there would otherwise vanish with
    no log line at all.
    """
    def _loop():
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("", EVENT_PORT))
        while True:
            data, _ = s.recvfrom(4096)
            try:
                callback(json.loads(data.decode()))
            except Exception:
                pass
    threading.Thread(target=_loop, daemon=True).start()


def is_valid_detection(detection: object) -> bool:
    """
    Defensive validation for a raw event straight off the wire, before
    it's trusted anywhere downstream -- attach_distance()/should_escalate()
    assume these keys exist and that direction is one of the three valid
    values. A malformed event (missing keys, wrong types, garbage
    direction) must be dropped here, not crash the pipeline later.
    """
    if not isinstance(detection, dict):
        return False
    if not all(key in detection for key in _REQUIRED_KEYS):
        return False
    return detection["direction"] in _VALID_DIRECTIONS


class CameraEventBridge:
    """
    Thread-safe bridge from listen_events()'s background-thread callback
    into an asyncio.Queue consumable via `async for detection in
    bridge.stream():`.

    Must be constructed from within the running event loop -- __init__
    calls asyncio.get_running_loop() to capture the loop reference the
    background thread's callback needs in order to safely schedule work
    back onto it.
    """

    def __init__(self) -> None:
        self._loop = asyncio.get_running_loop()
        self._queue: "asyncio.Queue[dict]" = asyncio.Queue(maxsize=_MAX_QUEUE_SIZE)

    def start(self) -> None:
        """Starts her background listener thread, wired to this bridge."""
        listen_events(self._on_event)
        logger.info("Camera event bridge listening on UDP port %d", EVENT_PORT)

    def _on_event(self, detection: dict) -> None:
        """
        Runs on listen_events()'s background thread -- must never touch
        self._queue directly (asyncio.Queue isn't thread-safe) and must
        never raise (see listen_events()'s docstring: her wrapper would
        silently swallow it, hiding a real bug). Validates first so a
        malformed event never reaches the queue at all, then hands the
        actual queue push to the event loop's own thread via
        call_soon_threadsafe().
        """
        try:
            if not is_valid_detection(detection):
                logger.warning("Dropping malformed camera detection event: %r", detection)
                return
            self._loop.call_soon_threadsafe(self._push, detection)
        except Exception as exc:  # noqa: BLE001 - must never raise, see docstring
            logger.error("Camera event bridge callback failed unexpectedly: %s", exc)

    def _push(self, detection: dict) -> None:
        # Runs on the event loop's own thread (scheduled via
        # call_soon_threadsafe above) -- safe to touch the asyncio queue here.
        try:
            self._queue.put_nowait(detection)
        except asyncio.QueueFull:
            # Same drop-oldest-keep-freshest policy as narration_queue.py.
            try:
                self._queue.get_nowait()
            except Exception:  # noqa: BLE001 - best-effort, never let this raise
                pass
            try:
                self._queue.put_nowait(detection)
            except Exception:  # noqa: BLE001 - see narration_queue.py: must never raise
                logger.warning("Camera event queue full even after dropping oldest, discarding: %r", detection)

    async def stream(self) -> AsyncIterator[dict]:
        """
        Yields one validated detection dict at a time, matching
        mock_detection_stream()'s shape, forever.
        """
        while True:
            yield await self._queue.get()
