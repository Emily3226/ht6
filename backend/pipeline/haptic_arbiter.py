"""
Pacing and priority arbitration for the haptic reflex path.

WHY THIS EXISTS: haptic_loop.py polls ToF at ~15Hz so detection latency
stays low, but the Apple Watch's Taptic Engine plays each buzz for
~1.5-2s -- broadcasting on every poll cycle (up to 15/sec) massively
overstimulates the user. This module sits between check_thresholds() and
the /ws/haptics broadcast and decides, per poll cycle, whether anything
should actually be sent: at most one direction at a time, at most once
every REMINDER_INTERVAL_SECONDS per direction, edge-triggered so the first
buzz on a new hazard is never delayed.

Deliberately independent of throttle.py, gemini_stage.py, and
narration_worker.py -- this is purely a broadcast-pacing layer for the
haptic path, not narration logic.
"""

from __future__ import annotations

import logging
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)

_DIRECTIONS = ("left", "right", "up")

# How often an unchanged, still-triggered direction may re-broadcast.
# Chosen to roughly match the Apple Watch Taptic Engine's own buzz
# duration (~1.5-2s) plus headroom, so reminders don't stack or feel
# continuous. Measured start-to-start (time between one broadcast and the
# next for the same direction), not gap-after-playback-ends.
REMINDER_INTERVAL_SECONDS = 4.0


class HapticArbiter:
    """
    Tracks per-direction pacing state and arbitrates which single
    direction (if any) should broadcast on a given poll cycle.

    Internal state is private -- callers should only ever use resolve();
    don't reach into _state or _winner directly.
    """

    def __init__(self) -> None:
        self._state: Dict[str, dict] = {
            direction: {"active": False, "last_broadcast_time": None}
            for direction in _DIRECTIONS
        }
        # The direction currently "holding" priority. Kept separate from
        # per-direction state since it can point at a direction whose
        # state has since reset (handled below).
        self._winner: Optional[str] = None

    def resolve(self, distances: dict, triggered: List[str], now: float) -> Optional[str]:
        """
        Call once per poll cycle with the latest distances, the list of
        currently-triggered directions (from haptic_trigger.check_thresholds()),
        and the current timestamp. Returns the single direction to
        broadcast this cycle, or None if nothing should be sent.
        """
        triggered_set = set(triggered)

        # Any direction that dropped below threshold gets a full reset --
        # a future re-trigger must be treated as brand new, not still
        # cooling down from before.
        for direction, state in self._state.items():
            if state["active"] and direction not in triggered_set:
                state["active"] = False
                state["last_broadcast_time"] = None

        # Track every currently-triggered direction as active, whether or
        # not it ends up winning this cycle -- a suppressed direction
        # still needs to be "known about" so that if it's later promoted,
        # its last_broadcast_time (still None, since it never actually
        # broadcast while suppressed) makes that promotion fire
        # immediately rather than waiting out a reminder interval.
        for direction in triggered:
            self._state[direction]["active"] = True

        # Priority winner: once picked, it KEEPS the role for as long as
        # it stays triggered, even if another direction becomes closer in
        # the meantime. This is intentional -- continuously re-comparing
        # distances would let two near-equal-distance, jittering hazards
        # flicker the winner back and forth every cycle, which is worse
        # for the user than briefly favoring a slightly-stale priority
        # pick. The winner is only re-evaluated once it actually clears.
        if self._winner is None or self._winner not in triggered_set:
            if not triggered:
                self._winner = None
                return None
            self._winner = min(triggered, key=lambda direction: distances[direction])

        winner_state = self._state[self._winner]
        prior_broadcast_time = winner_state["last_broadcast_time"]
        is_new = prior_broadcast_time is None
        elapsed = None if is_new else (now - prior_broadcast_time)
        should_broadcast = is_new or elapsed >= REMINDER_INTERVAL_SECONDS

        # DIAGNOSTIC (temporary): logs every cycle a winner exists, not just
        # on actual broadcasts, so the full timeline of triggers/reminders/
        # suppressions is visible -- including cycles where the winner
        # flips because it dropped out of `triggered` between calls.
        logger.debug(
            "resolve: winner=%s is_new=%s elapsed=%s should_broadcast=%s triggered=%s distances=%s",
            self._winner, is_new, elapsed, should_broadcast, triggered, distances,
        )

        if not should_broadcast:
            return None

        winner_state["last_broadcast_time"] = now
        return self._winner
