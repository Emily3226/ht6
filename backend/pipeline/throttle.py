"""
Stage 1.5: hazard narration throttling.

WHY THIS EXISTS: should_escalate() decides a detection is *worth* narrating,
but the hardware feed can fire many escalating detections per second while a
hazard is ongoing (e.g. someone standing 1m away for 30 seconds generates a
detection every frame). Without throttling, that turns into a Gemini call --
and a spoken narration in the user's ear -- every single frame. For a blind
cane user, that's not just wasteful API spend, it's actively harmful UX:
constant repeated "person ahead, person ahead, person ahead..." drowns out
the one thing that matters (is anything *new* happening?) and makes the
audio channel useless during exactly the moment it needs to be most useful.

HazardThrottle sits between should_escalate() and the rest of the pipeline
(frame capture + Gemini + broadcast) and answers one question per detection:
"has enough changed, or enough time passed, that the user should hear
something new?"
"""

from __future__ import annotations

import time
from typing import Callable, Optional, Tuple

Signature = Tuple[str, str]  # (object_class, direction)


class HazardThrottle:
    """
    Wraps escalation decisions with three rules, applied together:

    1. Signature dedup -- an ongoing hazard (same object_class + direction)
       is one hazard, not a new one every frame.
    2. Cooldown re-narration -- an ongoing hazard only gets re-narrated
       every `cooldown_s` seconds, UNLESS it changes in a way that counts
       as new information (different signature, or distance getting sharply
       worse), in which case it bypasses the cooldown immediately.
    3. Hard rate cap -- no matter what rules 1/2 decide, never call Gemini
       more than once per `hard_cap_s` seconds. This is the safety net for
       chaotic scenes (e.g. a crash) where the signature itself is
       constantly changing, so rule 2's "bypass on change" would otherwise
       let a flood of distinct signatures through back-to-back.

    Call should_narrate() once per detection that already passed
    should_escalate(). It returns True at most once per allowed narration
    and mutates internal state accordingly -- callers should treat a True
    return as "go ahead and call Gemini now."
    """

    def __init__(
        self,
        cooldown_s: float = 8.0,
        hard_cap_s: float = 3.0,
        worsening_delta_m: float = 0.5,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        # How long an *unchanged* ongoing hazard stays quiet between
        # re-narrations.
        self.cooldown_s = cooldown_s
        # Absolute floor between any two Gemini calls, regardless of
        # signature changes. Protects against chaotic multi-object scenes.
        self.hard_cap_s = hard_cap_s
        # How many meters closer an ongoing hazard has to get (relative to
        # the distance at its last narration) before we treat that as
        # "genuinely worse" and bypass the cooldown, even though the
        # signature (object_class, direction) hasn't changed.
        self.worsening_delta_m = worsening_delta_m
        # Injectable clock so tests can control time deterministically
        # instead of sleeping in real time.
        self._clock = clock

        self._active_signature: Optional[Signature] = None
        self._last_narrated_distance_m: Optional[float] = None
        self._last_narration_time: Optional[float] = None  # per active signature
        self._last_call_time: Optional[float] = None  # global, for the hard cap

    def should_narrate(self, detection: dict) -> bool:
        now = self._clock()
        signature: Signature = (detection["object_class"], detection["direction"])
        distance_m = detection["distance_m"]

        # --- Rule 3: hard rate cap, checked first and unconditionally. ---
        # This is a floor, not a suggestion -- even a brand-new signature or
        # a sharply-worsening hazard has to wait it out. Without this check
        # first, a chaotic scene where the signature changes every 200ms
        # (rule 2's bypass firing constantly) would still spam Gemini.
        if self._last_call_time is not None and (now - self._last_call_time) < self.hard_cap_s:
            return False

        signature_changed = signature != self._active_signature
        worsened = (
            not signature_changed
            and self._last_narrated_distance_m is not None
            and (self._last_narrated_distance_m - distance_m) >= self.worsening_delta_m
        )

        if signature_changed or worsened:
            # --- Rule 1 + Rule 2's bypass: new information, don't wait. ---
            # A new signature is a genuinely different hazard (different
            # object or it's now on a different side) -- the user needs to
            # know immediately, not after a stale cooldown. Likewise, if the
            # SAME object suddenly closes distance sharply, that's a
            # meaningfully more urgent situation than "still there," even
            # though nothing about the signature itself changed.
            self._active_signature = signature
            self._last_narrated_distance_m = distance_m
            self._last_narration_time = now
            self._last_call_time = now
            return True

        # --- Rule 2: same ongoing hazard, not worsening -> cooldown. ---
        # This is the case the whole class exists for: the hazard is still
        # there, the hardware is still firing detections for it every
        # frame, but nothing new has happened, so we hold off re-narrating
        # until cooldown_s has passed since we last spoke about it.
        if self._last_narration_time is not None and (now - self._last_narration_time) < self.cooldown_s:
            return False

        self._last_narrated_distance_m = distance_m
        self._last_narration_time = now
        self._last_call_time = now
        return True
