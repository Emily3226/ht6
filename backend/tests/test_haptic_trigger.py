"""
Unit tests for haptic_trigger.check_thresholds(), including hysteresis:
a direction newly crosses TRIGGER_THRESHOLD_M to become triggered, but only
clears once it rises back above the higher CLEAR_THRESHOLD_M.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline.haptic_trigger import CLEAR_THRESHOLD_M, TRIGGER_THRESHOLD_M, check_thresholds


def test_no_directions_triggered():
    assert check_thresholds({"left": 2.0, "right": 3.0, "up": 1.5}) == []


def test_one_direction_triggered_on_first_call():
    assert check_thresholds({"left": 0.5, "right": 3.0, "up": 1.5}) == ["left"]


def test_multiple_directions_triggered():
    result = check_thresholds({"left": 0.4, "right": 0.6, "up": 2.0})
    assert set(result) == {"left", "right"}


def test_all_directions_triggered():
    result = check_thresholds({"left": 0.1, "right": 0.2, "up": 0.3})
    assert set(result) == {"left", "right", "up"}


def test_custom_thresholds():
    assert check_thresholds({"left": 1.0}, trigger_threshold_m=1.5) == ["left"]
    assert check_thresholds({"left": 1.0}, trigger_threshold_m=0.5) == []


def test_clears_and_can_retrigger_when_previously_triggered_is_reset():
    # Simulates a caller that stops threading state through (e.g. a fresh
    # HapticArbiter-less consumer) -- with no previously_triggered passed,
    # every call is evaluated fresh against trigger_threshold_m.
    assert check_thresholds({"left": 0.2}) == ["left"]
    assert check_thresholds({"left": 5.0}) == []
    assert check_thresholds({"left": 0.2}) == ["left"]


def test_hysteresis_keeps_direction_triggered_while_jittering_in_band():
    # This is the core hysteresis case: a reading that dips just under
    # TRIGGER_THRESHOLD_M, then jitters around within the hysteresis band
    # (between the two thresholds) on subsequent calls, must stay
    # continuously triggered -- not reset -- since it never actually rises
    # above CLEAR_THRESHOLD_M.
    triggered = check_thresholds({"left": 0.74})
    assert triggered == ["left"]

    # Jitters back up past TRIGGER_THRESHOLD_M (0.75) but still well under
    # CLEAR_THRESHOLD_M (0.90) -- with a single threshold this would have
    # cleared; with hysteresis it must not.
    triggered = check_thresholds({"left": 0.85}, triggered)
    assert triggered == ["left"], "should stay triggered while jittering inside the hysteresis band"

    triggered = check_thresholds({"left": 0.78}, triggered)
    assert triggered == ["left"]

    triggered = check_thresholds({"left": 0.89}, triggered)
    assert triggered == ["left"], "0.89 is still under CLEAR_THRESHOLD_M (0.90)"

    # Only now does it actually clear -- distance rises to/above CLEAR_THRESHOLD_M.
    triggered = check_thresholds({"left": 0.95}, triggered)
    assert triggered == []


def test_hysteresis_does_not_delay_a_fresh_trigger():
    # A direction that is NOT currently triggered must still trigger
    # immediately at TRIGGER_THRESHOLD_M -- hysteresis only affects
    # clearing, never the initial trigger.
    assert check_thresholds({"left": 0.74}, previously_triggered=[]) == ["left"]
    assert check_thresholds({"left": 0.76}, previously_triggered=[]) == []


def test_hysteresis_is_per_direction_independent():
    triggered = check_thresholds({"left": 0.5, "right": 3.0, "up": 3.0})
    assert triggered == ["left"]

    # "left" jitters within its hysteresis band; "right" newly triggers;
    # "up" stays clear. Each direction's state must be evaluated
    # independently.
    triggered = check_thresholds({"left": 0.85, "right": 0.5, "up": 3.0}, triggered)
    assert set(triggered) == {"left", "right"}


def test_default_threshold_constants():
    # Sanity check the spec'd defaults haven't silently drifted, and that
    # the clear threshold is meaningfully higher than the trigger one.
    assert TRIGGER_THRESHOLD_M == 0.75
    assert CLEAR_THRESHOLD_M == 0.90
    assert CLEAR_THRESHOLD_M > TRIGGER_THRESHOLD_M
