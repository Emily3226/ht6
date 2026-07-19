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

from pipeline import tof_input

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
    Stage 1 filter: decide whether a detection is even worth treating as a
    potential hazard, before any throttling or Gemini calls happen.

    Returns True only if the object is close enough (distance_m below
    DISTANCE_THRESHOLD_M) AND the detector is confident enough (confidence
    above CONFIDENCE_THRESHOLD). Both conditions must hold -- a very close
    but low-confidence blip (sensor noise) shouldn't escalate, and neither
    should a confident detection of something far away.

    Requires attach_distance() to have already run on the detection: the
    camera (OAK-1-AF) has no depth perception, so a raw camera detection
    has no distance_m of its own -- distance is sourced from ToF at
    detection-time, not carried by the camera.

    distance_m may be None if attach_distance() couldn't get a real
    reading (see its docstring) -- this never escalates on an unknown
    distance. Escalating drives a real Gemini call and, via the throttle,
    a spoken narration; with no real reading to back up "this is close,"
    treating "unknown" as "close enough" risks narrating on fabricated
    proximity. Nothing is lost long-term either -- the next detection for
    the same object gets evaluated fresh once a real reading comes in.
    """
    distance_m = detection["distance_m"]
    if distance_m is None:
        return False
    return distance_m < DISTANCE_THRESHOLD_M and detection["confidence"] > CONFIDENCE_THRESHOLD


async def attach_distance(detection: dict) -> dict:
    """
    Stage 1 (pre-filter): attach a distance_m to a raw camera detection by
    looking up the current ToF reading for that detection's direction.

    The camera has no depth sensing of its own, so distance has to come
    from the separate ToF units. "center" isn't one of the three physical
    ToF sensors (left/right/up) -- for a center-direction detection we use
    whichever of left/right is closer, since a straight-ahead obstacle
    would show up on at least one of the two forward-facing sensors.

    None-safety: any ToF sensor can report None (no reading yet, or that
    unit isn't wired up -- see tof_input.py). For a direct left/right
    mapping, a None reading means distance is genuinely unknown, and is
    passed through as None rather than fabricated -- should_escalate()
    treats an unknown distance as "don't escalate." For "center" (min of
    left/right): if exactly one of the two is None, the other (known)
    value is used, since a real obstacle straight ahead would show up on
    at least one working forward sensor; if BOTH are None, the result is
    also None ("unknown"), never a fabricated number.

    Returns a new dict (does not mutate the input) with distance_m added
    alongside the original fields.
    """
    tof = await tof_input.read_all_tof()
    direction = detection["direction"]
    if direction == "center":
        left, right = tof["left"], tof["right"]
        if left is None:
            distance_m = right  # None if right is also None -- still "unknown"
        elif right is None:
            distance_m = left
        else:
            distance_m = min(left, right)
    else:
        distance_m = tof[direction]
    return {**detection, "distance_m": distance_m}


# ---------------------------------------------------------------------------
# Stage 1: mock input source. Swap for the real hardware feed later.
# ---------------------------------------------------------------------------

_DIRECTIONS = ("left", "center", "right")
_OBJECT_CLASSES = ("person", "pole", "bicycle", "curb", "vehicle", "chair")


def _make_detection(
    object_class: str,
    direction: str,
    confidence: float,
) -> dict:
    # No distance_m here -- the real OAK-1-AF camera has no depth
    # perception, so a raw detection never carries distance. Distance is
    # attached separately, from ToF, via attach_distance() at the point
    # main.py processes each detection.
    return {
        "timestamp": time.time(),
        "object_class": object_class,
        "direction": direction,
        "confidence": round(max(0.0, min(1.0, confidence)), 2),
    }


def mock_detection_stream(simulate_crash: bool = False) -> Iterator[dict]:
    """
    Fake detection generator standing in for the real hardware feed.

    Normal mode: yields one plausible detection every 1-3 seconds, roughly
    uniform over random object classes / directions -- enough variety to
    exercise should_escalate() (after attach_distance()) without spamming
    hazards.

    Crash mode (simulate_crash=True): yields rapid, jittery detections that
    share the same rough object_class/direction (so they *should* dedup as
    one ongoing hazard), arriving every 0.1-0.4 seconds continuously for
    about 2 minutes. Distance still fluctuates realistically in this mode
    -- that now comes for free from tof_input's own mock dip simulation,
    since attach_distance() re-reads ToF for every one of these rapid-fire
    detections. This is what a chaotic, sustained hazard looks like on the
    wire, and it's the scenario HazardThrottle exists to survive without
    spamming narration.

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

    start = time.time()
    while time.time() - start < duration_s:
        yield _make_detection(
            object_class=object_class,
            direction=direction,
            confidence=random.uniform(0.55, 0.98),
        )

        # Occasionally throw in a different object/direction to mimic a
        # multi-object chaotic scene -- this is what exercises the hard
        # rate cap rather than the cooldown/dedup rules.
        if random.random() < 0.15:
            yield _make_detection(
                object_class=random.choice(_OBJECT_CLASSES),
                direction=random.choice(_DIRECTIONS),
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
