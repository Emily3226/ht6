"""
Independent, unthrottled haptic reflex loop.

WHY THIS IS SEPARATE FROM THE CAMERA/GEMINI PIPELINE: haptic feedback needs
to be as close to instantaneous as a physical reflex -- there's no room for
a Gemini round-trip, a cooldown, or a dedup window between "a sensor reads
close" and "the user feels a buzz." This module must never import from or
await throttle.py or gemini_stage.py; it stays fully independent so nothing
in the narration pipeline can ever add latency here, and nothing here can
ever be delayed by a slow Gemini call.

The one addition to that rule: an "up" trigger also gets a spoken
narration (the camera can't see overhead, so there'd otherwise be no
narration at all for overhead hazards -- see narration_templates.py). That
still can't be allowed to slow this loop down, so it's a fire-and-forget
push onto narration_queue -- narration_queue.push_nowait() is
non-blocking and never raises, and everything downstream of it (throttle,
template lookup, broadcast) happens entirely in narration_worker.py, on
its own task, on its own time.
"""

from __future__ import annotations

import asyncio
import logging
import time

from pipeline import narration_queue, tof_input
from pipeline.haptic_arbiter import HapticArbiter
from pipeline.haptic_trigger import check_thresholds
from pipeline.server import broadcast_haptic

logger = logging.getLogger(__name__)

# ~15Hz sensor polling. check_thresholds() has no time-based debouncing --
# see haptic_trigger.py for its hysteresis (two distance thresholds, not a
# delay) -- so this rate is chosen purely for low detection latency; it is
# NOT the broadcast rate. HapticArbiter (below) is what
# actually paces /ws/haptics down to something the Apple Watch's Taptic
# Engine can physically play (each buzz runs ~1.5-2s): at most one
# direction broadcasting at a time, at most once every
# haptic_arbiter.REMINDER_INTERVAL_SECONDS per direction. Polling fast and
# broadcasting slow are two deliberately separate concerns -- don't couple
# them by changing this constant to "fix" perceived haptic pacing;
# retune REMINDER_INTERVAL_SECONDS in haptic_arbiter.py instead.
DEFAULT_POLL_INTERVAL_S = 1 / 15


async def run_haptic_loop(poll_interval_s: float = DEFAULT_POLL_INTERVAL_S) -> None:
    """
    Runs forever as its own independent asyncio background task: read all
    ToF sensors, check thresholds, resolve pacing/priority via a single
    persistent HapticArbiter, and broadcast at most one direction per
    cycle. Never awaits anything from the camera/Gemini pipeline, so it
    can't be slowed down by it.
    """
    logger.info("Haptic loop started (poll_interval_s=%s)", poll_interval_s)
    arbiter = HapticArbiter()
    # Carried across cycles and fed back into check_thresholds() each time
    # -- that's what gives its hysteresis continuity (which threshold
    # applies to a direction depends on whether it was already triggered
    # last cycle).
    triggered: list = []
    while True:
        # One bad cycle must never kill the loop: this task runs
        # unsupervised (create_task in the lifespan hook), so an uncaught
        # exception here doesn't crash the server -- it just silently
        # stops all haptics forever while everything else keeps working.
        try:
            # read_all_tof() is a real (blocking, HTTP) hardware call wrapped
            # in asyncio.to_thread() internally -- awaiting it here is safe
            # and doesn't block this loop's own scheduling, or anything else
            # on the event loop.
            distances = await tof_input.read_all_tof()
            triggered = check_thresholds(distances, triggered)

            for direction in triggered:
                if direction == "up":
                    # Unrelated to haptic pacing -- narration for overhead
                    # hazards has its own, separate throttle downstream in
                    # narration_worker.py, so this still fires every cycle
                    # "up" is triggered, regardless of what the arbiter
                    # decides for /ws/haptics below.
                    narration_queue.push_nowait({"source": "tof_up", "distance_m": distances["up"]})

            direction_to_broadcast = arbiter.resolve(distances, triggered, time.monotonic())
            if direction_to_broadcast is not None:
                await broadcast_haptic(direction_to_broadcast)
        except Exception:
            logger.exception("Haptic loop cycle failed; continuing")

        await asyncio.sleep(poll_interval_s)
