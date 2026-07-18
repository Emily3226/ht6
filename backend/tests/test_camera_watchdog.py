"""
Unit tests for CameraWatchdog. Uses plain float "now" values passed
directly (no need for a fancier fake-clock object, since both methods
already take `now` as an explicit parameter -- this is the equivalent of
running the test in fast-forward).
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline.camera_watchdog import WATCHDOG_TIMEOUT_SECONDS, CameraWatchdog


def test_regular_ok_heartbeats_stay_online_no_events():
    watchdog = CameraWatchdog(now=0.0)
    for t in [1.0, 2.0, 3.0, 4.0, 5.0]:
        assert watchdog.record_heartbeat("ok", t) is None
        assert watchdog.check_timeout(t) is None


def test_silence_past_timeout_fires_camera_offline_once():
    watchdog = CameraWatchdog(now=0.0)
    watchdog.record_heartbeat("ok", 1.0)

    # Well within the timeout window -- nothing fires.
    assert watchdog.check_timeout(1.0 + WATCHDOG_TIMEOUT_SECONDS - 1) is None

    # Past the timeout window since the last heartbeat.
    t_offline = 1.0 + WATCHDOG_TIMEOUT_SECONDS + 0.1
    assert watchdog.check_timeout(t_offline) == "camera_offline"

    # Still offline, still silent -- must not fire again on subsequent calls.
    assert watchdog.check_timeout(t_offline + 1.0) is None
    assert watchdog.check_timeout(t_offline + 100.0) is None


def test_heartbeat_after_offline_fires_camera_restored_once():
    watchdog = CameraWatchdog(now=0.0)
    watchdog.record_heartbeat("ok", 1.0)
    t_offline = 1.0 + WATCHDOG_TIMEOUT_SECONDS + 0.1
    assert watchdog.check_timeout(t_offline) == "camera_offline"

    # First heartbeat since going offline -- restores.
    assert watchdog.record_heartbeat("ok", t_offline + 1.0) == "camera_restored"

    # Further "ok" heartbeats while already online -- no repeat.
    assert watchdog.record_heartbeat("ok", t_offline + 2.0) is None


def test_explicit_error_heartbeat_triggers_offline_immediately():
    watchdog = CameraWatchdog(now=0.0)
    watchdog.record_heartbeat("ok", 1.0)

    # Far short of the timeout window -- only the explicit error should
    # cause this transition, not elapsed time.
    assert watchdog.record_heartbeat("error", 1.5) == "camera_offline"


def test_repeated_error_heartbeats_while_offline_fire_nothing_further():
    watchdog = CameraWatchdog(now=0.0)
    watchdog.record_heartbeat("ok", 1.0)
    assert watchdog.record_heartbeat("error", 1.5) == "camera_offline"

    assert watchdog.record_heartbeat("error", 2.0) is None
    assert watchdog.record_heartbeat("error", 3.0) is None
    assert watchdog.check_timeout(4.0) is None


def test_never_receiving_a_heartbeat_still_times_out_eventually():
    # No heartbeat at all since construction -- should still be detected,
    # using construction time as the initial reference point.
    watchdog = CameraWatchdog(now=100.0)
    assert watchdog.check_timeout(100.0 + WATCHDOG_TIMEOUT_SECONDS - 1) is None
    assert watchdog.check_timeout(100.0 + WATCHDOG_TIMEOUT_SECONDS + 0.1) == "camera_offline"


def test_recovery_then_failing_again_fires_each_transition_once():
    watchdog = CameraWatchdog(now=0.0)
    watchdog.record_heartbeat("ok", 1.0)
    assert watchdog.record_heartbeat("error", 2.0) == "camera_offline"
    assert watchdog.record_heartbeat("ok", 3.0) == "camera_restored"
    assert watchdog.record_heartbeat("error", 4.0) == "camera_offline"
    assert watchdog.record_heartbeat("ok", 5.0) == "camera_restored"
