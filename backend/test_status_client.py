"""
Mirrors test_client.py / test_haptic_client.py, but for the camera-status
path: connects to ws://localhost:8765/ws/status and prints each incoming
event with a local timestamp. You should see nothing at all during normal
operation (no news is good news -- this channel only speaks on state
transitions), then a single "camera_offline" after triggering a simulated
failure and waiting out the timeout, then a single "camera_restored" once
heartbeats resume.

Usage:
    python test_status_client.py                       # ws://localhost:8765/ws/status
    python test_status_client.py ws://192.168.1.5:8765/ws/status
"""

import asyncio
import datetime
import json
import sys

import websockets

DEFAULT_URL = "ws://localhost:8765/ws/status"


async def main(url: str) -> None:
    print(f"Connecting to {url} ...")
    async with websockets.connect(url) as ws:
        print("Connected. Waiting for status events (Ctrl+C to quit)...")
        print("(Nothing should print during normal operation -- this channel is silent")
        print(" except on actual camera_offline/camera_restored transitions.)")
        async for raw_message in ws:
            message = json.loads(raw_message)
            timestamp = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
            print(f"[{timestamp}] {message}")


if __name__ == "__main__":
    target_url = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_URL
    try:
        asyncio.run(main(target_url))
    except KeyboardInterrupt:
        pass
