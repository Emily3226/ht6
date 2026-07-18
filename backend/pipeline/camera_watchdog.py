"""
Detects camera-pipeline failure from heartbeat activity (or the lack of
it), independent of anything narration/haptic-related.

WHY THIS EXISTS: without an explicit heartbeat, "camera saw nothing worth
narrating" and "camera process crashed" look identical downstream -- both
just mean no hazard messages arrive. That's a real gap for a blind cane
user: silence should mean "nothing's there," not possibly "the safety
system is dead and I don't know it." CameraWatchdog turns heartbeat
activity (or silence) into an explicit online/offline signal.

Two independent ways a failure gets detected:
- Explicit: the camera reports {"status": "error", ...} itself --
  transitions to offline immediately, no need to wait for a timeout.
- Implicit: the camera goes silent entirely (crash, hang, unplugged) --
  only detectable by the ABSENCE of heartbeats for too long, which is why
  check_timeout() has to be called periodically on its own schedule,
  independent of whether any heartbeat ever arrives again.
"""

from __future__ import annotations

from typing import Optional

# ~2.4x HEARTBEAT_INTERVAL_SECONDS (5.0s) -- long enough that one missed or
# delayed heartbeat doesn't false-positive, short enough that a real crash
# is caught quickly.
WATCHDOG_TIMEOUT_SECONDS = 12.0


class CameraWatchdog:
    """
    Tracks believed camera state ("online"/"offline") and fires a
    transition event exactly once per actual state change -- never
    repeated while steady, same "don't spam" principle as the rest of
    this project's narration/haptic paths.
    """

    def __init__(self, now: float) -> None:
        # `now` at construction seeds _last_seen -- without this, a camera
        # that never sends a single heartbeat from startup would leave
        # _last_seen unset and check_timeout() would have nothing to
        # measure against, silently never detecting "never even started."
        # Seeding it at construction time means that failure mode times
        # out exactly like a mid-session crash would.
        self._last_seen = now
        self._state = "online"

    def record_heartbeat(self, status: str, now: float) -> Optional[str]:
        """
        Call whenever a heartbeat (ok or error) arrives. Returns
        "camera_offline" or "camera_restored" if this heartbeat caused a
        state transition, None otherwise.
        """
        self._last_seen = now

        if status == "error":
            if self._state == "online":
                self._state = "offline"
                return "camera_offline"
            return None  # already offline -- no repeat

        # status == "ok"
        if self._state == "offline":
            self._state = "online"
            return "camera_restored"
        return None  # already online -- steady state, nothing to report

    def check_timeout(self, now: float) -> Optional[str]:
        """
        Call periodically (independent of whether a heartbeat arrives) to
        detect silence. Returns "camera_offline" if too much time has
        passed since the last heartbeat and we were still online, None
        otherwise -- including while already offline, so this can be
        called repeatedly during an outage without repeated events.
        """
        if self._state == "online" and (now - self._last_seen) > WATCHDOG_TIMEOUT_SECONDS:
            self._state = "offline"
            return "camera_offline"
        return None
