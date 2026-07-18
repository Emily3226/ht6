"""
Stage 1 + Stage 2: detection ingest/filter, and frame capture.

INTEGRATION POINT #1 (real hardware): mock_detection_stream() below stands
in for the teammate's OAK-1-AF + ToF hardware pipeline. Swap it for the real
feed by writing a generator (or async generator) with the same shape --
yielding dicts matching the detection contract -- and pointing main.py at it
instead.

INTEGRATION POINT #2 (real camera): capture_frame() stands in for a real
camera grab. See its docstring below.
"""

from __future__ import annotations

import io
import random
import time
from typing import Iterator

from PIL import Image

# ---------------------------------------------------------------------------
# Stage 1: escalation thresholds. Kept as module-level constants so they're
# easy to find and tune without hunting through function bodies.
# ---------------------------------------------------------------------------

# A detection only counts as a candidate hazard if the object is closer than
# this many meters...
DISTANCE_THRESHOLD_M = 2.0

# ...AND the detector is at least this confident it's real.
CONFIDENCE_THRESHOLD = 0.5


def should_escalate(detection: dict) -> bool:
    """
    Stage 1 filter: decide whether a raw detection is even worth treating as
    a potential hazard, before any throttling or Gemini calls happen.

    Returns True only if the object is close enough (distance_m below
    DISTANCE_THRESHOLD_M) AND the detector is confident enough (confidence
    above CONFIDENCE_THRESHOLD). Both conditions must hold -- a very close
    but low-confidence blip (sensor noise) shouldn't escalate, and neither
    should a confident detection of something far away.
    """
    return (
        detection["distance_m"] < DISTANCE_THRESHOLD_M
        and detection["confidence"] > CONFIDENCE_THRESHOLD
    )


# ---------------------------------------------------------------------------
# Stage 1: mock input source. Swap for the real hardware feed later.
# ---------------------------------------------------------------------------

_DIRECTIONS = ("left", "center", "right")
_OBJECT_CLASSES = ("person", "pole", "bicycle", "curb", "vehicle", "chair")


def _make_detection(
    object_class: str,
    direction: str,
    distance_m: float,
    confidence: float,
) -> dict:
    return {
        "timestamp": time.time(),
        "object_class": object_class,
        "direction": direction,
        "confidence": round(max(0.0, min(1.0, confidence)), 2),
        "distance_m": round(max(0.05, distance_m), 2),
    }


def mock_detection_stream(simulate_crash: bool = False) -> Iterator[dict]:
    """
    Fake detection generator standing in for the real hardware feed.

    Normal mode: yields one plausible detection every 1-3 seconds, roughly
    uniform over random object classes / directions / distances -- enough
    variety to exercise should_escalate() without spamming hazards.

    Crash mode (simulate_crash=True): yields rapid, jittery detections that
    share the same rough object_class/direction (so they *should* dedup as
    one ongoing hazard) but with fluctuating distance/confidence, arriving
    every 0.1-0.4 seconds continuously for about 2 minutes. This is what a
    chaotic, sustained hazard looks like on the wire, and it's the scenario
    HazardThrottle exists to survive without spamming narration.

    This is a plain generator so it's trivial to swap for a real source --
    e.g. an async generator reading off a socket/queue from the hardware
    process -- as long as it yields dicts matching the same contract.
    """
    if simulate_crash:
        yield from _simulate_crash_stream()
        return

    while True:
        yield _make_detection(
            object_class=random.choice(_OBJECT_CLASSES),
            direction=random.choice(_DIRECTIONS),
            distance_m=random.uniform(0.3, 4.0),
            confidence=random.uniform(0.3, 0.99),
        )
        time.sleep(random.uniform(1.0, 3.0))


def _simulate_crash_stream(duration_s: float = 120.0) -> Iterator[dict]:
    """
    A sustained, chaotic hazard: one dominant object/direction that keeps
    re-triggering the detector, plus occasional shifting distractors, so
    the throttle has to tell "same hazard, still there" apart from
    "genuinely new hazard" apart from "just noisy."
    """
    object_class = random.choice(_OBJECT_CLASSES)
    direction = random.choice(_DIRECTIONS)
    base_distance = random.uniform(0.8, 1.8)

    start = time.time()
    while time.time() - start < duration_s:
        # Jitter distance/confidence around a slowly-drifting baseline so
        # this looks like a real object bobbling in the frame, not a
        # perfectly repeated packet.
        base_distance = max(0.3, base_distance + random.uniform(-0.3, 0.2))
        yield _make_detection(
            object_class=object_class,
            direction=direction,
            distance_m=base_distance,
            confidence=random.uniform(0.55, 0.98),
        )

        # Occasionally throw in a different object/direction to mimic a
        # multi-object chaotic scene -- this is what exercises the hard
        # rate cap rather than the cooldown/dedup rules.
        if random.random() < 0.15:
            yield _make_detection(
                object_class=random.choice(_OBJECT_CLASSES),
                direction=random.choice(_DIRECTIONS),
                distance_m=random.uniform(0.5, 2.5),
                confidence=random.uniform(0.5, 0.95),
            )

        time.sleep(random.uniform(0.1, 0.4))


# ---------------------------------------------------------------------------
# Stage 2: frame capture. Swap for the real camera grab later.
# ---------------------------------------------------------------------------

def capture_frame() -> bytes:
    """
    Placeholder frame capture.

    INTEGRATION POINT: replace this with the real OAK-1-AF frame grab (e.g.
    pulling the latest JPEG off the camera's output queue) once that
    hardware is wired up. Keep the signature (-> bytes of a JPEG image) the
    same so gemini_stage.analyze_hazard() doesn't need to change.

    For now, generates a solid-color placeholder image with Pillow so the
    rest of the pipeline (encoding, sending to Gemini, etc.) can be
    exercised end-to-end without real camera hardware.
    """
    image = Image.new("RGB", (640, 480), color=(80, 80, 80))
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG")
    return buffer.getvalue()
