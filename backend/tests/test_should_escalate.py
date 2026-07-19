"""
Unit tests for detection_input.should_escalate(), including its None
handling: an unknown distance_m (e.g. attach_distance() couldn't get a
real ToF reading) must never escalate -- the safer default, since
escalating drives a real Gemini call and a spoken narration with no real
distance to back up "this is close."
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline.detection_input import CONFIDENCE_THRESHOLD, DISTANCE_THRESHOLD_M, should_escalate


def _detection(distance_m, confidence: float = 0.9) -> dict:
    return {
        "timestamp": 0,
        "object_class": "person",
        "direction": "center",
        "confidence": confidence,
        "distance_m": distance_m,
    }


def test_escalates_when_close_and_confident():
    assert should_escalate(_detection(distance_m=1.0, confidence=0.9)) is True


def test_does_not_escalate_when_far():
    assert should_escalate(_detection(distance_m=DISTANCE_THRESHOLD_M + 0.1, confidence=0.9)) is False


def test_does_not_escalate_when_low_confidence():
    assert should_escalate(_detection(distance_m=1.0, confidence=CONFIDENCE_THRESHOLD - 0.1)) is False


def test_none_distance_does_not_escalate():
    # Unknown distance (e.g. that direction's ToF sensor hasn't reported
    # yet, or isn't wired up) must not be treated as "close enough" --
    # even with high confidence, this must not escalate, and must not
    # raise trying to compare None against DISTANCE_THRESHOLD_M.
    assert should_escalate(_detection(distance_m=None, confidence=0.99)) is False
