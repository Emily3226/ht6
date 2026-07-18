"""
Direct haptic reflex threshold check, with hysteresis.

No time-based debouncing or cooldown -- if a sensor currently reads close
enough to trigger, the user needs to feel that buzz right now, not after
some delay decides it's "new enough" to bother with. That kind of smoothing
is exactly right for spoken narration (see throttle.py's HazardThrottle,
which exists precisely to avoid repeating itself) but wrong here -- a
missed or delayed buzz is far worse than an occasional repeated one.

HYSTERESIS: a direction that ISN'T currently triggered still becomes
triggered the instant its distance drops below TRIGGER_THRESHOLD_M -- that
part is unchanged and still immediate. But a direction that IS currently
triggered only clears once its distance rises back above the higher
CLEAR_THRESHOLD_M, instead of clearing the moment a single reading crosses
back over the trigger threshold. The gap between the two thresholds absorbs
sensor jitter: a reading wobbling between, say, 0.7m and 0.85m around one
physical object no longer flips triggered/cleared on every poll cycle --
which it did with a single threshold, and which was flooding /ws/haptics
with spurious resets/re-triggers for what was really one continuous
hazard, even after tof_input.py's dip-smoothing fix (that fix reduced how
often a dip's readings wander across a threshold, but couldn't eliminate
it when a dip's baseline happens to land close to one -- this closes that
remaining gap).

This does mean check_thresholds() is no longer a pure function of
`distances` alone -- it needs to know what was triggered last call to know
which threshold applies to each direction now. Rather than hide that as
module-level state, it's threaded through explicitly via
`previously_triggered`, so the function itself stays easy to test and
reason about in isolation; the caller (haptic_loop.py) is responsible for
holding onto the return value and passing it back in next cycle.
"""

from __future__ import annotations

from typing import Container, List

# A direction not currently triggered becomes triggered the instant its
# distance drops below this.
TRIGGER_THRESHOLD_M = 0.75

# A direction that IS currently triggered only clears once its distance
# rises back above this -- deliberately higher than TRIGGER_THRESHOLD_M so
# a reading jittering anywhere between the two can't flip state every call.
CLEAR_THRESHOLD_M = 0.90


def check_thresholds(
    distances: dict,
    previously_triggered: Container[str] = frozenset(),
    trigger_threshold_m: float = TRIGGER_THRESHOLD_M,
    clear_threshold_m: float = CLEAR_THRESHOLD_M,
) -> List[str]:
    """
    Given a {"left": ..., "right": ..., "up": ...} distance reading (as
    returned by tof_input.read_all_tof()) and the list/set of directions
    this function returned on the PREVIOUS call, returns the directions
    currently triggered under hysteresis. Can be empty, one direction, or
    all of them.

    Call it like `triggered = check_thresholds(distances, triggered)` in a
    loop -- passing the previous return value back in is what gives
    hysteresis continuity across calls. On the very first call (nothing
    previously triggered), every direction is evaluated against
    trigger_threshold_m, same as before hysteresis existed.
    """
    triggered = []
    for direction, distance_m in distances.items():
        is_currently_triggered = direction in previously_triggered
        threshold = clear_threshold_m if is_currently_triggered else trigger_threshold_m
        if distance_m < threshold:
            triggered.append(direction)
    return triggered
