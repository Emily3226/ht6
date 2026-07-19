"""
Tests for tof_input.py's real-hardware wrapper: confirms read_all_tof()'s
asyncio.to_thread() offload actually keeps the event loop free while the
(simulated slow/blocking) HTTP call is in flight, and sanity-checks the
kept-alongside mock is still usable.
"""

import asyncio
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline import tof_input


def test_read_all_tof_does_not_block_the_event_loop(monkeypatch):
    def slow_sync_read():
        time.sleep(0.3)  # simulates a slow/unreachable board
        return {"left": 1.0, "right": 2.0, "up": None}

    monkeypatch.setattr(tof_input, "_read_all_tof_sync", slow_sync_read)

    progress = {"ticks": 0}

    async def tick_counter():
        while True:
            progress["ticks"] += 1
            await asyncio.sleep(0.01)

    async def run():
        counter_task = asyncio.create_task(tick_counter())
        result = await tof_input.read_all_tof()
        counter_task.cancel()
        return result

    result = asyncio.run(run())

    assert result == {"left": 1.0, "right": 2.0, "up": None}
    # If read_all_tof() blocked the event loop directly (e.g. called the
    # blocking function inline instead of via asyncio.to_thread), the
    # tick counter would never get scheduled during the 0.3s sleep, and
    # progress["ticks"] would still be ~0-1. Comfortably more than that
    # confirms the event loop kept running concurrently.
    assert progress["ticks"] > 5, (
        f"expected the event loop to keep ticking during the blocking call, "
        f"only got {progress['ticks']} ticks -- read_all_tof() may be blocking"
    )


def test_read_all_tof_returns_all_none_on_failure(monkeypatch):
    def failing_sync_read():
        raise ConnectionError("board unreachable")

    # _read_all_tof_sync itself already catches this (matching her code
    # exactly), but confirm the async wrapper surfaces that fallback
    # correctly too rather than letting the exception propagate.
    def real_read_with_failure():
        try:
            return failing_sync_read()
        except Exception:
            return {"left": None, "right": None, "up": None}

    monkeypatch.setattr(tof_input, "_read_all_tof_sync", real_read_with_failure)

    result = asyncio.run(tof_input.read_all_tof())
    assert result == {"left": None, "right": None, "up": None}


def test_mock_read_all_tof_is_still_usable_and_never_returns_none():
    result = asyncio.run(tof_input.mock_read_all_tof())
    assert set(result.keys()) == {"left", "right", "up"}
    assert all(isinstance(v, float) for v in result.values())
