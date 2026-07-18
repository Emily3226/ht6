"""
Unit tests for HazardThrottle. Uses an injectable fake clock so the tests
run instantly and deterministically instead of sleeping in real time.
"""

import sys
from pathlib import Path

# Make `pipeline` importable when running `pytest` from backend/ without
# installing the project as a package.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline.throttle import HazardThrottle


def make_detection(object_class="person", direction="left", distance_m=1.0):
    return {
        "timestamp": 0,
        "object_class": object_class,
        "direction": direction,
        "confidence": 0.9,
        "distance_m": distance_m,
    }


class FakeClock:
    """Controllable clock: advance(seconds) moves time forward explicitly."""

    def __init__(self, start: float = 0.0):
        self.now = start

    def advance(self, seconds: float) -> None:
        self.now += seconds

    def __call__(self) -> float:
        return self.now


def test_first_detection_always_narrates():
    clock = FakeClock()
    throttle = HazardThrottle(cooldown_s=8.0, hard_cap_s=3.0, clock=clock)

    assert throttle.should_narrate(make_detection()) is True


def test_same_signature_repeated_rapidly_is_mostly_suppressed():
    clock = FakeClock()
    throttle = HazardThrottle(cooldown_s=8.0, hard_cap_s=3.0, clock=clock)

    # First detection narrates.
    assert throttle.should_narrate(make_detection(distance_m=1.0)) is True

    # Same signature, same rough distance, firing every 0.5s (much faster
    # than either cooldown or hard cap) for a while -- almost all of these
    # should be suppressed.
    results = []
    for _ in range(14):  # 7 seconds of rapid-fire detections
        clock.advance(0.5)
        results.append(throttle.should_narrate(make_detection(distance_m=1.0)))

    assert not any(results), "no re-narration should happen before cooldown elapses"

    # Cooldown (8s) has now elapsed since the first narration -- next
    # detection should be allowed through.
    clock.advance(1.0)  # total elapsed since first narration: 8.0s
    assert throttle.should_narrate(make_detection(distance_m=1.0)) is True


def test_changing_signature_bypasses_cooldown():
    clock = FakeClock()
    throttle = HazardThrottle(cooldown_s=8.0, hard_cap_s=3.0, clock=clock)

    assert throttle.should_narrate(make_detection(object_class="person", direction="left")) is True

    # Wait past the hard cap (so the change isn't blocked by rule 3), but
    # nowhere near the cooldown -- a signature change should still get
    # through immediately.
    clock.advance(3.5)
    assert throttle.should_narrate(make_detection(object_class="pole", direction="right")) is True


def test_signature_change_still_respects_hard_cap():
    clock = FakeClock()
    throttle = HazardThrottle(cooldown_s=8.0, hard_cap_s=3.0, clock=clock)

    assert throttle.should_narrate(make_detection(object_class="person", direction="left")) is True

    # Signature changes immediately, but well within the hard cap window --
    # rule 3 is an unconditional floor, so this must still be blocked.
    clock.advance(1.0)
    assert throttle.should_narrate(make_detection(object_class="pole", direction="right")) is False


def test_sharp_worsening_bypasses_cooldown_without_signature_change():
    clock = FakeClock()
    throttle = HazardThrottle(
        cooldown_s=8.0, hard_cap_s=3.0, worsening_delta_m=0.5, clock=clock
    )

    assert throttle.should_narrate(make_detection(direction="left", distance_m=1.8)) is True

    # Past hard cap, same signature, distance barely changed -- should
    # still be suppressed by cooldown.
    clock.advance(3.5)
    assert throttle.should_narrate(make_detection(direction="left", distance_m=1.7)) is False

    # Distance now sharply worse (drop >= 0.5m from the last *narrated*
    # distance of 1.8m) -- should bypass cooldown even though the
    # signature (person, left) hasn't changed.
    clock.advance(0.1)
    assert throttle.should_narrate(make_detection(direction="left", distance_m=1.2)) is True


def test_rapidly_changing_signature_is_capped_by_hard_rate_limit():
    clock = FakeClock()
    throttle = HazardThrottle(cooldown_s=8.0, hard_cap_s=3.0, clock=clock)

    objects = ["person", "pole", "bicycle", "vehicle"]
    directions = ["left", "center", "right"]

    narrate_count = 0
    total_ticks = 40
    for i in range(total_ticks):
        clock.advance(0.2)  # a new, different signature every 200ms
        detection = make_detection(
            object_class=objects[i % len(objects)],
            direction=directions[i % len(directions)],
            distance_m=1.0,
        )
        if throttle.should_narrate(detection):
            narrate_count += 1

    # Total elapsed time is 8 seconds; with a 3s hard cap, at most
    # floor(8 / 3) + 1 = 3 calls should have gotten through, regardless of
    # how many distinct signatures fired.
    elapsed_s = total_ticks * 0.2
    max_allowed = int(elapsed_s // throttle.hard_cap_s) + 1
    assert narrate_count <= max_allowed
    assert narrate_count > 0
