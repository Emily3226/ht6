"""
Wires the full pipeline together and runs it as a background task alongside
uvicorn:

    mock detection stream -> should_escalate() -> HazardThrottle.should_narrate()
        -> capture_frame() -> analyze_hazard() -> broadcast_hazard()

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

from pipeline.detection_input import capture_frame, mock_detection_stream, should_escalate
from pipeline.gemini_stage import analyze_hazard
from pipeline.server import DEFAULT_PORT, app, broadcast_hazard, get_local_ip
from pipeline.throttle import HazardThrottle

logger = logging.getLogger(__name__)


async def run_pipeline(simulate_crash: bool) -> None:
    """
    The core pipeline loop. Runs forever as a background asyncio task
    alongside uvicorn, feeding every escalated + throttled detection
    through Gemini and out over the WebSocket.
    """
    stream = mock_detection_stream(simulate_crash=simulate_crash)
    throttle = HazardThrottle()

    logger.info("Pipeline started (simulate_crash=%s)", simulate_crash)

    while True:
        # mock_detection_stream is a plain blocking generator (it paces
        # itself with time.sleep). Running next() in a worker thread keeps
        # that sleep from blocking the event loop uvicorn needs to keep
        # WebSocket connections alive.
        #
        # INTEGRATION POINT (real hardware): if the real feed is itself
        # async (e.g. reading off a socket), swap this for a plain
        # `async for detection in real_stream:` and drop the to_thread call.
        detection = await asyncio.to_thread(next, stream)

        if not should_escalate(detection):
            continue
        if not throttle.should_narrate(detection):
            continue

        frame = capture_frame()
        hazard = await analyze_hazard(frame, detection)
        await broadcast_hazard(hazard)
        logger.info("Broadcast hazard: %s", hazard)


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
    app.state.on_startup = lambda: run_pipeline(app.state.simulate_crash)

    local_ip = get_local_ip()
    print(f"Health check:        http://{local_ip}:{DEFAULT_PORT}/health")
    print(f"Swift app should connect to: ws://{local_ip}:{DEFAULT_PORT}/ws/hazards")
    if app.state.simulate_crash:
        print("CRASH SIMULATION MODE enabled -- sustained chaotic hazard stream for ~2 minutes.")

    uvicorn.run(app, host="0.0.0.0", port=DEFAULT_PORT)


if __name__ == "__main__":
    main()
