"""
Consumes narration_queue.queue, unifying both narration origins -- camera
detections and overhead ToF triggers -- through the same HazardThrottle
instance and the same /ws/hazards broadcast, even though they produce
their spoken descriptions in completely different ways (a Gemini vision
call vs a fixed template), since the camera literally cannot see overhead.

THROTTLE TIMING: should_narrate() runs BEFORE the Gemini call or template
lookup, not after -- exactly where it ran in the original camera-only
pipeline (should_escalate -> should_narrate -> capture_frame -> Gemini).
Two reasons this matters, not just style:

1. Cost/latency: HazardThrottle's hard rate cap exists specifically to
   bound how often the expensive Gemini call happens during a chaotic
   scene (see throttle.py's own docstring: "never call Gemini more than
   once per hard_cap_s seconds"). Checking it after analysis would let
   every escalated camera detection hit Gemini regardless of cooldown --
   only the broadcast would be throttled, silently defeating the point of
   the rate cap during exactly the scenario it was built for.
2. Signature stability: throttle dedup is keyed on (object_class,
   direction). The camera's object_class is a stable, discrete label
   ("person", "pole", ...); Gemini's hazard_type is free-text generated
   per call and could vary for the same physical object across calls
   (e.g. "pole" vs "street sign"), which would silently break dedup if
   used as the signature key instead.

For a tof_up event (no real "detection" from a camera), a synthetic probe
dict is built with a fixed object_class of "overhead_obstacle" so it gets
its own stable, distinct signature -- same throttle instance, same rules,
no forking of throttle.py's logic.
"""

from __future__ import annotations

import logging

from pipeline import narration_queue
from pipeline.gemini_stage import analyze_hazard
from pipeline.narration_templates import build_up_hazard
from pipeline.server import broadcast_hazard
from pipeline.throttle import HazardThrottle

logger = logging.getLogger(__name__)


async def _handle_event(event: dict, throttle: HazardThrottle) -> None:
    source = event.get("source")

    if source == "camera":
        detection = event["detection"]
        if not throttle.should_narrate(detection):
            return
        # Defense in depth: main.py's run_pipeline() already skips pushing
        # a camera event onto narration_queue at all when capture_frame()
        # returns None (frame capture failed), so this should never
        # actually trigger today -- but if any future caller ever pushes a
        # frameless camera event here, a bad/empty image must never reach
        # Gemini or produce a broadcast based on nothing.
        frame = event["frame"]
        if frame is None:
            logger.warning("Camera event has no frame, skipping narration: %s", detection)
            return
        hazard = await analyze_hazard(frame, detection)

    elif source == "tof_up":
        # No camera detection exists for this origin -- build a stable
        # signature probe so throttle.should_narrate() can dedup/cooldown
        # overhead hazards exactly like any other (object_class, direction)
        # pair, without needing any changes to throttle.py itself.
        distance_m = event["distance_m"]
        probe = {
            "object_class": "overhead_obstacle",
            "direction": "up",
            "distance_m": distance_m,
        }
        if not throttle.should_narrate(probe):
            return
        hazard = build_up_hazard(distance_m)

    else:
        logger.warning("Unknown narration_queue event source: %r", source)
        return

    await broadcast_hazard(hazard)
    logger.info("Broadcast hazard (%s): %s", source, hazard)


async def run_narration_worker(throttle: HazardThrottle) -> None:
    """
    Runs forever as its own background task, consuming events pushed by
    both main.py's run_pipeline() (camera) and haptic_loop.py (tof_up).
    """
    logger.info("Narration worker started")
    while True:
        event = await narration_queue.queue.get()
        await _handle_event(event, throttle)
