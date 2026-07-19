"""
ToF (time-of-flight) sensor reads: three units, one each facing left,
right, and up/overhead.

read_all_tof() (below) is the ACTIVE, real-hardware implementation, added
2026-07-19 -- it's the ONLY interface to ToF hardware, called by both the
haptic loop (~15Hz) and the camera detection path (occasionally, via
detection_input.attach_distance()). mock_read_all_tof() is the original
simulated version from before real hardware was wired up -- kept alongside
(not deleted), for tests and any hardware-less development. Swap it in
explicitly (e.g. monkeypatch or import it directly) if the real board
isn't reachable.

Her board serves distances over plain HTTP, synchronously
(requests.Session().get(...).json()) -- blocking, and this gets called
from an asyncio event loop at ~15Hz. Calling it directly would freeze the
entire event loop -- hazard broadcasts, /ws/status checks, every other
background task -- for up to its 0.5s timeout, on every single poll, not
just the haptic loop's own cadence. asyncio.to_thread() keeps it off the
loop.
"""

from __future__ import annotations

import asyncio
import random
import threading

import requests

# Real hardware, provided by teammate -- her board's fixed IP on the
# hotspot network this hardware is tested on. Hardcoded to match her code
# exactly (no env var): this is specific to this physical board, not a
# per-deployment config value.
BOARD_IP = "172.20.10.2"

_session = requests.Session()


def _read_all_tof_sync() -> dict:
    """
    Blocking HTTP call to the real ToF board -- her code, unmodified.

    Returns {"left": 2.1, "right": 3.4, "up": None} in meters. A None
    value means "no reading for that direction" -- e.g. that sensor unit
    isn't wired up yet, or hasn't reported since startup. On ANY failure
    (board unreachable, timeout, bad/non-JSON response), returns
    {"left": None, "right": None, "up": None} rather than raising, so
    callers never need to handle a request exception directly -- only
    None values.
    """
    try:
        data = _session.get(f"http://{BOARD_IP}:8080/tof", timeout=0.5).json()
        # Sanitize: only the three known directions, only numeric values.
        # A malformed/partial response (error JSON, string values, extra
        # keys) must degrade to None readings, never leak junk downstream
        # -- one bad value reaching check_thresholds() raises and silently
        # kills the whole haptic loop task for good.
        return {
            direction: (float(data[direction])
                        if isinstance(data.get(direction), (int, float))
                        and not isinstance(data.get(direction), bool)
                        else None)
            for direction in ("left", "right", "up")
        }
    except Exception:
        return {"left": None, "right": None, "up": None}


async def read_all_tof() -> dict:
    """
    Async wrapper around the real hardware read -- the ACTIVE
    implementation. Both haptic_loop.py and
    detection_input.attach_distance() await this.

    Runs the blocking HTTP call in a worker thread (asyncio.to_thread) so
    a slow or unreachable board (up to the 0.5s timeout above, on every
    ~15Hz poll) can never freeze the event loop the rest of the server
    depends on.

    Any of the three distances may be None (see _read_all_tof_sync's
    docstring) -- every caller of this function must treat None as "no
    reading, don't trigger, don't escalate," never as 0 or otherwise
    falsely close.
    """
    return await asyncio.to_thread(_read_all_tof_sync)


# ---------------------------------------------------------------------------
# Mock ToF: the original simulated implementation, kept alongside the real
# one above (not deleted) for tests and hardware-less development. Nothing
# in the active pipeline calls this anymore -- import and use
# mock_read_all_tof() explicitly if you need it.
# ---------------------------------------------------------------------------

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

# Guards the shared per-direction dip state below. Called concurrently and
# at very different rates by the haptic loop (~15Hz) and the camera path
# (occasionally) when the mock is in use -- without this lock, two calls
# interleaving their read-then-write of _dip_remaining could corrupt a
# direction's counter (e.g. both see 0, both decide to start a dip, one
# update clobbers the other's). A plain threading.Lock (not asyncio.Lock)
# is used deliberately: the underlying logic has no internal await points.
_lock = threading.Lock()
_dip_remaining = {direction: 0 for direction in _DIRECTIONS}
_dip_baseline_m = {direction: 0.0 for direction in _DIRECTIONS}


def force_dip(direction: str, distance_m: float = 0.5, calls: int = 25) -> None:
    """
    Manually start a dip on one MOCK sensor, as if a real object just came
    within `distance_m`. Used by the /simulate/tof/{direction} endpoint so
    the phone app can rehearse the full sensor -> haptic/narration flow on
    demand. At the haptic loop's ~15Hz poll, 25 calls ≈ 1.7s of sustained
    near readings -- comfortably enough for haptic_trigger's hysteresis to
    latch the direction.

    NOTE (2026-07-19): only affects mock_read_all_tof()'s internal state.
    Now that the active pipeline calls the real read_all_tof() above
    instead, this no longer has any effect on live haptic/narration
    behavior unless something is explicitly wired back to
    mock_read_all_tof() -- /simulate/tof's demo hook is stale until/unless
    that endpoint is updated separately.
    """
    if direction not in _DIRECTIONS:
        raise ValueError(f"direction must be one of {_DIRECTIONS}, got {direction!r}")
    with _lock:
        _dip_baseline_m[direction] = distance_m
        _dip_remaining[direction] = calls


def _mock_read_all_tof_sync() -> dict:
    """
    Returns a simulated distance reading (meters) for each of the three
    ToF sensors, e.g. {"left": 2.1, "right": 3.4, "up": 0.6}.

    Each direction independently sits at a baseline of 2-4m most of the
    time, occasionally dipping to 0.2-1.0m for a handful of consecutive
    calls (simulating something approaching and then clearing) before
    recovering. Consecutive readings within the same dip stay close
    together (jittered around that dip's own baseline distance, not
    independently redrawn each call -- see _DIP_JITTER_M above), so one
    continuous dip reads as one continuous close approach rather than
    flickering across a threshold. Safe to call rapidly and concurrently
    from multiple callers at once. Never returns None -- that's a
    real-hardware-only possibility.
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


async def mock_read_all_tof() -> dict:
    """
    Async-signature-compatible mock -- a drop-in swap for read_all_tof()
    above wherever the real board isn't reachable (tests, hardware-less
    dev). No actual blocking I/O here (pure in-memory simulation), so no
    asyncio.to_thread() offload is needed -- this returns directly.
    """
    return _mock_read_all_tof_sync()
