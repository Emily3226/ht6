"""
Mock ToF (time-of-flight) sensor reads: three independent units, one each
facing left, right, and up/overhead.

INTEGRATION POINT (real hardware): read_all_tof() is the ONLY interface to
ToF hardware -- both the haptic loop (calling 50-100x/sec) and the camera
detection path (calling occasionally, via detection_input.attach_distance())
go through this same function. When the real hardware read is ready, swap
the body of read_all_tof() for the real sensor read and keep the signature
(-> dict with "left"/"right"/"up" float keys) identical so neither caller
needs to change.

Real ToF hardware is naturally pull-based (ask the sensor, get its current
reading) rather than push-based, which is why this is a plain function
rather than a stream/generator -- that matches how the real version will
work too.
"""

from __future__ import annotations

import random
import threading

_DIRECTIONS = ("left", "right", "up")

_BASELINE_MIN_M = 2.0
_BASELINE_MAX_M = 4.0
_NEAR_MIN_M = 0.2
_NEAR_MAX_M = 1.0

# Odds, on any single call where a direction isn't already "dipping", that
# it starts a new dip this call. Kept low so dips read as occasional
# (something passing through), not constant.
_DIP_START_CHANCE = 0.01
_DIP_MIN_CALLS = 5
_DIP_MAX_CALLS = 20

# How much a dip's reading is allowed to wander, per call, around that
# dip's own baseline distance. A real object sitting ~0.5m away for a
# fraction of a second doesn't teleport across most of the 0.2-1.0m near
# range between two ~15Hz polls -- but drawing a fresh independent
# uniform(0.2, 1.0) on every call (the original approach) did exactly
# that, so a single continuous dip could straddle a caller's near-distance
# threshold (e.g. haptic_trigger's default 0.75m) many times per second,
# making one physical "object approaching" event look like it was
# repeatedly clearing and re-triggering. Small jitter around a fixed
# per-dip baseline keeps consecutive readings within one dip close
# together, so it reads as one continuous close approach instead.
_DIP_JITTER_M = 0.05

# Guards the shared per-direction dip state below. read_all_tof() is called
# concurrently and at very different rates by the haptic loop (50-100Hz)
# and the camera path (occasionally) -- without this lock, two calls
# interleaving their read-then-write of _dip_remaining could corrupt a
# direction's counter (e.g. both see 0, both decide to start a dip, one
# update clobbers the other's). A plain threading.Lock (not asyncio.Lock)
# is used deliberately: this function has no internal await points and may
# eventually be called from a real hardware SDK's own worker thread, not
# just asyncio tasks.
_lock = threading.Lock()
_dip_remaining = {direction: 0 for direction in _DIRECTIONS}
_dip_baseline_m = {direction: 0.0 for direction in _DIRECTIONS}


def force_dip(direction: str, distance_m: float = 0.5, calls: int = 25) -> None:
    """
    Manually start a dip on one mock sensor, as if a real object just came
    within `distance_m`. Used by the /simulate/tof/{direction} endpoint so
    the phone app can rehearse the full sensor -> haptic/narration flow on
    demand. At the haptic loop's ~15Hz poll, 25 calls ≈ 1.7s of sustained
    near readings -- comfortably enough for haptic_trigger's hysteresis to
    latch the direction.
    """
    if direction not in _DIRECTIONS:
        raise ValueError(f"direction must be one of {_DIRECTIONS}, got {direction!r}")
    with _lock:
        _dip_baseline_m[direction] = distance_m
        _dip_remaining[direction] = calls


def read_all_tof() -> dict:
    """
    Returns the current mock distance reading (meters) for each of the
    three ToF sensors, e.g. {"left": 2.1, "right": 3.4, "up": 0.6}.

    Each direction independently sits at a baseline of 2-4m most of the
    time, occasionally dipping to 0.2-1.0m for a handful of consecutive
    calls (simulating something approaching and then clearing) before
    recovering. Consecutive readings within the same dip stay close
    together (jittered around that dip's own baseline distance, not
    independently redrawn each call -- see _DIP_JITTER_M above), so one
    continuous dip reads as one continuous close approach rather than
    flickering across a threshold. Safe to call rapidly and concurrently
    from multiple callers at once.
    """
    readings = {}
    with _lock:
        for direction in _DIRECTIONS:
            if _dip_remaining[direction] > 0:
                _dip_remaining[direction] -= 1
                jittered = _dip_baseline_m[direction] + random.uniform(-_DIP_JITTER_M, _DIP_JITTER_M)
                readings[direction] = round(min(_NEAR_MAX_M, max(_NEAR_MIN_M, jittered)), 2)
            elif random.random() < _DIP_START_CHANCE:
                baseline = random.uniform(_NEAR_MIN_M, _NEAR_MAX_M)
                _dip_baseline_m[direction] = baseline
                _dip_remaining[direction] = random.randint(_DIP_MIN_CALLS, _DIP_MAX_CALLS) - 1
                readings[direction] = round(baseline, 2)
            else:
                readings[direction] = round(random.uniform(_BASELINE_MIN_M, _BASELINE_MAX_M), 2)
    return readings
