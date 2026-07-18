"""
Minimal manual test client: connects to the hazard WebSocket and prints
every message it receives, so you can watch narrations arrive (and watch
the throttle suppress most of them during --simulate-crash) without needing
the Swift app running.

Usage:
    python test_client.py                       # connects to ws://localhost:8765/ws/hazards
    python test_client.py ws://192.168.1.5:8765/ws/hazards   # connect elsewhere
"""

import asyncio
import json
import sys

import websockets

DEFAULT_URL = "ws://localhost:8765/ws/hazards"


async def main(url: str) -> None:
    print(f"Connecting to {url} ...")
    async with websockets.connect(url) as ws:
        print("Connected. Waiting for hazard messages (Ctrl+C to quit)...")
        async for raw_message in ws:
            message = json.loads(raw_message)
            print(json.dumps(message, indent=2))


if __name__ == "__main__":
    target_url = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_URL
    try:
        asyncio.run(main(target_url))
    except KeyboardInterrupt:
        pass
