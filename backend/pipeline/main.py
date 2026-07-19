"""
Wires the full pipeline together and runs it as four independent
background tasks alongside uvicorn:

    real camera detection events (CameraEventBridge, or mock_detection_stream
        in --simulate-crash mode) -> attach_distance() -> should_escalate()
        -> capture_frame() -> narration_queue.push_nowait({"source": "camera", ...})

    mock ToF -> haptic_loop's check_thresholds() -> broadcast_haptic() (immediate, unthrottled)
                                                  \\-> narration_queue.push_nowait({"source": "tof_up", ...})
                                                      (fire-and-forget, "up" only)

    narration_queue -> narration_worker: HazardThrottle.should_narrate() (one shared
        instance, checked BEFORE analysis) -> analyze_hazard() or
        narration_templates.build_up_hazard() -> broadcast_hazard()

    mock heartbeat stream -> CameraWatchdog (record_heartbeat + periodic
        check_timeout) -> broadcast_status() on /ws/status, transitions only

Camera detections and overhead ("up") ToF triggers are two different
origins that meet at narration_worker.py and share one HazardThrottle
instance and one /ws/hazards broadcast from there on -- see
narration_worker.py's docstring for why the throttle check happens before
(not after) Gemini/template analysis. The camera-status path
(status_loop.py) is entirely separate from all of this -- see its
docstring for why.

Run with:
    python -m pipeline.main                  # normal mode
    python -m pipeline.main --simulate-crash  # sustained chaotic-hazard demo

Or set the SIMULATE_CRASH=true environment variable instead of the flag.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os

from dotenv import load_dotenv

# Load .env (GEMINI_API_KEY, etc.) before anything else touches the
# environment.
load_dotenv()

import uvicorn

from pipeline import narration_queue
from pipeline.camera_events import CameraEventBridge
from pipeline.detection_input import (
    attach_distance,
    capture_frame,
    mock_detection_stream,
    should_escalate,
)
from pipeline.haptic_loop import run_haptic_loop
from pipeline.narration_worker import run_narration_worker
from pipeline.server import DEFAULT_PORT, app, broadcast_hazard, get_local_ip, manager
from pipeline.status_loop import run_status_loop
from pipeline.throttle import HazardThrottle

logger = logging.getLogger(__name__)


async def _process_detection(detection: dict) -> None:
    """
    Shared post-processing for a raw detection, regardless of which
    source (real camera events or the mock crash-stream) produced it.
    """
    # The camera has no depth perception -- attach_distance() has to run
    # before should_escalate() can even look at distance_m. Async since it
    # awaits the real (HTTP, off-thread) ToF read.
    detection = await attach_distance(detection)

    if not should_escalate(detection):
        return

    # capture_frame() is now the real camera board (2026-07-19) -- a
    # blocking HTTP call wrapped in asyncio.to_thread() internally, so
    # awaiting it here doesn't block anything else on the event loop even
    # though it can take up to FRAME_TIMEOUT_S. Captured here (before
    # queueing) so the queued event stays self-contained. This does mean a
    # frame gets requested for every escalated detection, even ones the
    # throttle will end up dropping -- unlike the Gemini call throttle
    # still gates downstream in narration_worker, but that's the existing,
    # accepted tradeoff for having one unified queue event shape.
    #
    # A None frame (board unreachable/timed out/bad response -- see
    # capture_frame()'s docstring) means there's nothing to show Gemini:
    # log it and drop this detection entirely rather than pushing a
    # frameless event downstream. Haptics (the fast/safety-critical path)
    # never depended on this and keeps working regardless.
    frame = await capture_frame()
    if frame is None:
        logger.warning("Frame capture failed, skipping narration for detection: %s", detection)
        return

    narration_queue.push_nowait({"source": "camera", "detection": detection, "frame": frame})


async def run_pipeline(simulate_crash: bool) -> None:
    """
    Camera-originated half of the narration pipeline. By default, consumes
    real detection events from the camera board via CameraEventBridge
    (see camera_events.py). With --simulate-crash / SIMULATE_CRASH set,
    uses mock_detection_stream()'s crash-mode generator instead -- kept
    working deliberately, so HazardThrottle's chaotic-scene behavior can
    still be demoed/verified on demand without needing the real hardware
    to misbehave on cue (the same reasoning tof_input.py's kept mock
    exists for).

    Either way, filters raw detections and pushes the ones worth analyzing
    onto narration_queue -- throttling and Gemini analysis happen in
    narration_worker.py, the single place both narration origins (camera
    and overhead ToF) meet.
    """
    logger.info("Pipeline started (simulate_crash=%s)", simulate_crash)

    if simulate_crash:
        # mock_detection_stream is a plain blocking generator (it paces
        # itself with time.sleep). Running next() in a worker thread keeps
        # that sleep from blocking the event loop uvicorn needs to keep
        # WebSocket connections alive.
        stream = mock_detection_stream(simulate_crash=True)
        while True:
            detection = await asyncio.to_thread(next, stream)
            await _process_detection(detection)
    else:
        # CameraEventBridge must be constructed from within the running
        # event loop (it captures asyncio.get_running_loop()) -- this is
        # that context.
        bridge = CameraEventBridge()
        bridge.start()
        async for detection in bridge.stream():
            await _process_detection(detection)


# The mock data never produces an "urgent" hazard on its own: the overhead
# template path tops out at "high", and gemini_stage's urgent gate would
# downgrade anything the fake gray frames produced anyway. Since "urgent" is
# the one tier that raises the SOS overlay on the watch, this one-shot task
# scripts it: as soon as the first Swift client connects to /ws/hazards,
# broadcast a single urgent hazard so the SOS flow leads the demo. The short
# delay just gives the app a beat to finish setting up after connecting;
# it's well under the mock stream's own pacing + Gemini latency, so this is
# effectively always the first hazard the app hears.
URGENT_DEMO_DELAY_S = 2.0

URGENT_DEMO_HAZARD = {
    "hazard_type": "vehicle",
    "direction": "center",
    "urgency": "urgent",
    "spoken_description": "Danger. Vehicle approaching directly ahead. Move back now.",
}


async def run_urgent_demo_once() -> None:
    while not manager.has_clients():
        await asyncio.sleep(0.5)
    await asyncio.sleep(URGENT_DEMO_DELAY_S)
    await broadcast_hazard(URGENT_DEMO_HAZARD)
    logger.info("Urgent demo hazard broadcast: %s", URGENT_DEMO_HAZARD)


def _resolve_simulate_crash(cli_flag: bool) -> bool:
    if cli_flag:
        return True
    return os.getenv("SIMULATE_CRASH", "").strip().lower() in ("1", "true", "yes")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Hazard detection pipeline server")
    parser.add_argument(
        "--simulate-crash",
        action="store_true",
        help=(
            "Run mock_detection_stream in sustained chaotic-hazard mode "
            "(~2 minutes of rapid jittery detections) to demo/verify "
            "HazardThrottle's cooldown and rate-cap behavior."
        ),
    )
    return parser.parse_args()


def main() -> None:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )

    args = parse_args()
    app.state.simulate_crash = _resolve_simulate_crash(args.simulate_crash)

    # One shared HazardThrottle instance for both narration origins
    # (camera detections and overhead ToF triggers) -- narration_worker is
    # the only thing that calls it, so dedup/cooldown/rate-cap state stays
    # consistent across both.
    throttle = HazardThrottle()

    # Four fully independent background tasks -- the lifespan hook in
    # server.py starts each as its own asyncio task, so a slow Gemini call
    # in narration_worker can never delay run_haptic_loop, run_pipeline, or
    # run_status_loop (camera health monitoring), or vice versa.
    app.state.on_startup_tasks = [
        lambda: run_pipeline(app.state.simulate_crash),
        run_haptic_loop,
        lambda: run_narration_worker(throttle),
        run_status_loop,
        run_urgent_demo_once,
    ]

    local_ip = get_local_ip()
    print(f"Health check:        http://{local_ip}:{DEFAULT_PORT}/health")
    print(f"Swift app should connect to: ws://{local_ip}:{DEFAULT_PORT}/ws/hazards")
    print(f"Haptic reflex path:  ws://{local_ip}:{DEFAULT_PORT}/ws/haptics")
    print(f"Camera status path:  ws://{local_ip}:{DEFAULT_PORT}/ws/status")
    print(f"SOS demo: one URGENT hazard fires first, ~{URGENT_DEMO_DELAY_S:.0f}s after the app connects.")
    if app.state.simulate_crash:
        print("CRASH SIMULATION MODE enabled -- sustained chaotic hazard stream for ~2 minutes.")

    uvicorn.run(app, host="0.0.0.0", port=DEFAULT_PORT)


if __name__ == "__main__":
    main()
