"""
Unit tests for detection_input.attach_distance(). Now async (it awaits
tof_input.read_all_tof(), the real hardware call) -- uses asyncio.run()
directly, matching the convention already used elsewhere in this test
suite (e.g. test_narration_worker.py), rather than adding a
pytest-asyncio dependency.
"""

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline import detection_input


def _detection(direction: str) -> dict:
    return {
        "timestamp": 0,
        "object_class": "person",
        "direction": direction,
        "confidence": 0.9,
    }


def _patch_tof(monkeypatch, readings: dict):
    async def fake_read_all_tof():
        return readings

    monkeypatch.setattr(detection_input.tof_input, "read_all_tof", fake_read_all_tof)


def test_attach_distance_left(monkeypatch):
    _patch_tof(monkeypatch, {"left": 1.1, "right": 2.2, "up": 3.3})
    detection = _detection("left")
    result = asyncio.run(detection_input.attach_distance(detection))

    assert result["distance_m"] == 1.1
    # Original fields preserved; input dict left untouched.
    assert result["object_class"] == "person"
    assert "distance_m" not in detection


def test_attach_distance_right(monkeypatch):
    _patch_tof(monkeypatch, {"left": 1.1, "right": 2.2, "up": 3.3})
    result = asyncio.run(detection_input.attach_distance(_detection("right")))
    assert result["distance_m"] == 2.2


def test_attach_distance_center_uses_min_of_left_right(monkeypatch):
    _patch_tof(monkeypatch, {"left": 1.1, "right": 0.9, "up": 3.3})
    result = asyncio.run(detection_input.attach_distance(_detection("center")))
    assert result["distance_m"] == 0.9

    _patch_tof(monkeypatch, {"left": 0.4, "right": 2.5, "up": 3.3})
    result = asyncio.run(detection_input.attach_distance(_detection("center")))
    assert result["distance_m"] == 0.4


# ---------------------------------------------------------------------------
# None handling: the real ToF board can report None for a direction with
# no reading (not wired up, or hasn't reported since startup). None must
# propagate as "unknown," never get fabricated into a number.
# ---------------------------------------------------------------------------

def test_attach_distance_left_none_stays_none(monkeypatch):
    _patch_tof(monkeypatch, {"left": None, "right": 2.2, "up": 3.3})
    result = asyncio.run(detection_input.attach_distance(_detection("left")))
    assert result["distance_m"] is None


def test_attach_distance_right_none_stays_none(monkeypatch):
    _patch_tof(monkeypatch, {"left": 1.1, "right": None, "up": 3.3})
    result = asyncio.run(detection_input.attach_distance(_detection("right")))
    assert result["distance_m"] is None


def test_attach_distance_center_one_side_none_uses_the_other(monkeypatch):
    _patch_tof(monkeypatch, {"left": None, "right": 1.5, "up": 3.3})
    result = asyncio.run(detection_input.attach_distance(_detection("center")))
    assert result["distance_m"] == 1.5

    _patch_tof(monkeypatch, {"left": 0.6, "right": None, "up": 3.3})
    result = asyncio.run(detection_input.attach_distance(_detection("center")))
    assert result["distance_m"] == 0.6


def test_attach_distance_center_both_none_is_none(monkeypatch):
    _patch_tof(monkeypatch, {"left": None, "right": None, "up": 3.3})
    result = asyncio.run(detection_input.attach_distance(_detection("center")))
    assert result["distance_m"] is None
