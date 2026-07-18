"""
Unit tests for HapticArbiter: pacing (edge-triggered, then capped to one
broadcast per REMINDER_INTERVAL_SECONDS), priority arbitration (closest
wins, holds the role until it clears), and promotion (immediate broadcast,
no waiting out a reminder interval).
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline.haptic_arbiter import REMINDER_INTERVAL_SECONDS, HapticArbiter


def test_single_direction_immediate_then_paced_then_reminder():
    arbiter = HapticArbiter()
    distances = {"left": 0.5, "right": 3.0, "up": 3.0}

    # Edge-triggered: first cycle broadcasts immediately.
    assert arbiter.resolve(distances, ["left"], now=0.0) == "left"

    # Still triggered, well within the reminder interval -- suppressed.
    assert arbiter.resolve(distances, ["left"], now=1.0) is None
    assert arbiter.resolve(distances, ["left"], now=2.0) is None
    assert arbiter.resolve(distances, ["left"], now=3.9) is None

    # Reminder interval elapsed (measured start-to-start) -- broadcasts again.
    assert arbiter.resolve(distances, ["left"], now=4.0) == "left"

    # And is suppressed again immediately afterward.
    assert arbiter.resolve(distances, ["left"], now=4.5) is None


def test_clear_then_retrigger_is_immediate_not_still_cooling_down():
    arbiter = HapticArbiter()
    distances = {"left": 0.5, "right": 3.0, "up": 3.0}

    assert arbiter.resolve(distances, ["left"], now=0.0) == "left"
    assert arbiter.resolve(distances, ["left"], now=1.0) is None

    # Direction clears (drops out of triggered) well before the reminder
    # interval would have elapsed.
    assert arbiter.resolve(distances, [], now=1.5) is None

    # Re-triggers shortly after -- must be treated as brand new, not still
    # under the old cooldown.
    assert arbiter.resolve(distances, ["left"], now=1.6) == "left"


def test_two_directions_only_closer_one_broadcasts():
    arbiter = HapticArbiter()
    distances = {"left": 0.3, "right": 1.0, "up": 3.0}

    assert arbiter.resolve(distances, ["left", "right"], now=0.0) == "left"
    # "right" never broadcasts while "left" (closer) is the active winner.
    assert arbiter.resolve(distances, ["left", "right"], now=0.5) is None
    assert arbiter.resolve(distances, ["left", "right"], now=1.0) is None
    assert arbiter.resolve(distances, ["left", "right"], now=4.0) == "left"


def test_winner_holds_role_even_if_other_becomes_closer():
    arbiter = HapticArbiter()

    # "left" starts out closer and wins.
    distances = {"left": 1.0, "right": 2.0, "up": 3.0}
    assert arbiter.resolve(distances, ["left", "right"], now=0.0) == "left"

    # "right" becomes much closer than "left" while both are still
    # triggered -- the winner must NOT flip to "right".
    distances = {"left": 1.0, "right": 0.1, "up": 3.0}
    assert arbiter.resolve(distances, ["left", "right"], now=1.0) is None
    assert arbiter.resolve(distances, ["left", "right"], now=4.0) == "left"
    # "right" still never broadcasts.
    assert arbiter.resolve(distances, ["left", "right"], now=4.5) is None


def test_promotion_on_winner_clearing_is_immediate():
    arbiter = HapticArbiter()
    distances = {"left": 1.0, "right": 2.0, "up": 3.0}

    assert arbiter.resolve(distances, ["left", "right"], now=0.0) == "left"
    assert arbiter.resolve(distances, ["left", "right"], now=1.0) is None

    # "left" (the winner) clears; "right" was suppressed the whole time and
    # never actually broadcast, so its promotion must be immediate -- not
    # wait out a reminder interval.
    assert arbiter.resolve(distances, ["right"], now=1.1) == "right"


def test_three_directions_sequential_promotion_order():
    arbiter = HapticArbiter()
    distances = {"left": 2.0, "right": 1.0, "up": 0.5}

    # Closest ("up") wins initially; the other two are suppressed.
    assert arbiter.resolve(distances, ["left", "right", "up"], now=0.0) == "up"
    assert arbiter.resolve(distances, ["left", "right", "up"], now=1.0) is None

    # "up" clears -> "right" (next closest of the remaining) is promoted
    # immediately.
    assert arbiter.resolve(distances, ["left", "right"], now=1.1) == "right"
    assert arbiter.resolve(distances, ["left", "right"], now=1.2) is None

    # "right" clears -> "left" is promoted immediately.
    assert arbiter.resolve(distances, ["left"], now=1.3) == "left"


def test_nothing_triggered_returns_none():
    arbiter = HapticArbiter()
    assert arbiter.resolve({"left": 3.0, "right": 3.0, "up": 3.0}, [], now=0.0) is None


def test_reminder_interval_constant_is_four_seconds():
    # Sanity check the spec'd default hasn't silently drifted.
    assert REMINDER_INTERVAL_SECONDS == 4.0
