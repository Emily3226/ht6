"""
Independent camera-status background task: consumes the heartbeat stream
and independently polls for timeout, both driving one persistent
CameraWatchdog, broadcasting on /ws/status only on actual transitions.

Deliberately independent of throttle.py, gemini_stage.py,
narration_queue.py, haptic_loop.py, and haptic_arbiter.py -- a bug or slow
call in any of those must never be able to block camera-status detection,
and this task must never be able to affect them either. It shares nothing
with them but the FastAPI app object itself (for the /ws/status broadcast).
"""

from __future__ import annotations

import asyncio
import logging
import time

from pipeline.camera_watchdog import CameraWatchdog
from pipeline.heartbeat_input import mock_heartbeat_stream
from pipeline.server import broadcast_status

logger = logging.getLogger(__name__)

# How often check_timeout() is polled, independent of heartbeat arrivals --
# this is what catches silence (a heartbeat that never comes) rather than
# relying on the next heartbeat to notice the gap.
TIMEOUT_CHECK_INTERVAL_SECONDS = 1.0


async def _consume_heartbeats(watchdog: CameraWatchdog) -> None:
    async for heartbeat in mock_heartbeat_stream():
        event = watchdog.record_heartbeat(heartbeat["status"], time.monotonic())
        if event is not None:
            await broadcast_status(event, time.time())
            logger.info("Camera status event (from heartbeat): %s", event)


async def _poll_timeout(watchdog: CameraWatchdog) -> None:
    while True:
        await asyncio.sleep(TIMEOUT_CHECK_INTERVAL_SECONDS)
        event = watchdog.check_timeout(time.monotonic())
        if event is not None:
            await broadcast_status(event, time.time())
            logger.info("Camera status event (from timeout): %s", event)


async def run_status_loop() -> None:
    """
    Runs forever as its own independent background task: one
    CameraWatchdog instance, shared by two concurrent coroutines (heartbeat
    consumption and periodic timeout polling) for the task's whole
    lifetime.
    """
    watchdog = CameraWatchdog(now=time.monotonic())
    logger.info("Camera status loop started")
    await asyncio.gather(
        _consume_heartbeats(watchdog),
        _poll_timeout(watchdog),
    )
