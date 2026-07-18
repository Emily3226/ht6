"""
Stage 4: FastAPI app exposing the WebSocket endpoint the Swift app connects
to, plus a health check.

WebSocket contract (fixed -- the Swift app decodes exactly this shape, no
extra fields): {hazard_type, direction, urgency, spoken_description}.
"""

from __future__ import annotations

import asyncio
import collections
import logging
import socket
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

logger = logging.getLogger(__name__)

# Default port matches the placeholder already hardcoded in the Swift app's
# Config.swift (ws://<ip>:8765) -- only the IP needs updating there, not the
# port, once this server is running on your machine.
DEFAULT_PORT = 8765


@asynccontextmanager
async def lifespan(app: FastAPI):
    # main.py sets app.state.on_startup_tasks to a list of zero-arg async
    # callables before calling uvicorn.run(), so this stays free of any
    # main.py-specific pipeline wiring -- server.py only knows "run each of
    # these coroutines as its own independent background task while the
    # app is up." Each gets its own task (not one task sequentially
    # awaiting all of them) specifically so the hazard pipeline and the
    # haptic loop run concurrently and neither can block the other.
    startup_hooks = getattr(app.state, "on_startup_tasks", None) or []
    tasks = [asyncio.create_task(hook()) for hook in startup_hooks]
    try:
        yield
    finally:
        for task in tasks:
            task.cancel()


app = FastAPI(lifespan=lifespan)


class ConnectionManager:
    """Tracks connected Swift clients and broadcasts hazard JSON to all of them."""

    def __init__(self) -> None:
        self._connections: list[WebSocket] = []

    async def connect(self, websocket: WebSocket) -> None:
        await websocket.accept()
        self._connections.append(websocket)
        logger.info("Client connected (%d total)", len(self._connections))

    def disconnect(self, websocket: WebSocket) -> None:
        if websocket in self._connections:
            self._connections.remove(websocket)
        logger.info("Client disconnected (%d total)", len(self._connections))

    async def broadcast(self, message: dict) -> None:
        # Iterate over a copy since a failed send mutates self._connections
        # via disconnect() during iteration.
        for websocket in list(self._connections):
            try:
                await websocket.send_json(message)
            except Exception as exc:  # noqa: BLE001 - a dead socket shouldn't kill the broadcast
                logger.warning("Failed to send to a client, dropping it: %s", exc)
                self.disconnect(websocket)


manager = ConnectionManager()


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.websocket("/ws/hazards")
async def ws_hazards(websocket: WebSocket) -> None:
    await manager.connect(websocket)
    try:
        while True:
            # This pipeline only ever pushes hazard events out; it doesn't
            # currently act on anything the Swift client sends. We still
            # need to await receive() to detect disconnects promptly.
            await websocket.receive_text()
    except WebSocketDisconnect:
        manager.disconnect(websocket)


async def broadcast_hazard(hazard: dict) -> None:
    """
    Called by main.py once a detection has cleared should_escalate(),
    HazardThrottle, and Gemini analysis. Sends exactly the fixed contract
    fields -- nothing else -- to every connected Swift client.
    """
    payload = {
        "hazard_type": hazard["hazard_type"],
        "direction": hazard["direction"],
        "urgency": hazard["urgency"],
        "spoken_description": hazard["spoken_description"],
    }
    await manager.broadcast(payload)


# ---------------------------------------------------------------------------
# Haptic reflex path: independent of everything above. Own connection
# manager, own endpoint, own (non-)throttling rules.
# ---------------------------------------------------------------------------

haptic_manager = ConnectionManager()

# Safety valve, NOT intentional throttling -- HazardThrottle's cooldown/dedup
# logic is a deliberate UX choice for narration; this cap has no such
# purpose. It exists purely so a runaway bug (e.g. a ToF glitch or a logic
# error in haptic_loop polling far faster than intended) can't flood the
# WebSocket / Watch. Under normal operation this should never bind.
_HAPTIC_RATE_CAP_PER_SEC = 20
_haptic_send_timestamps: "collections.deque[float]" = collections.deque()


def _haptic_rate_limit_ok() -> bool:
    now = time.monotonic()
    while _haptic_send_timestamps and now - _haptic_send_timestamps[0] > 1.0:
        _haptic_send_timestamps.popleft()
    if len(_haptic_send_timestamps) >= _HAPTIC_RATE_CAP_PER_SEC:
        return False
    _haptic_send_timestamps.append(now)
    return True


@app.websocket("/ws/haptics")
async def ws_haptics(websocket: WebSocket) -> None:
    await haptic_manager.connect(websocket)
    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        haptic_manager.disconnect(websocket)


async def broadcast_haptic(direction: str) -> None:
    """
    Called by haptic_loop.py whenever a ToF reading crosses the near
    threshold for a direction. Sends exactly {"direction": direction} --
    one message per triggered direction, not combined -- to every
    connected Swift client. Valid directions: "left", "right", "up".
    """
    if not _haptic_rate_limit_ok():
        logger.warning(
            "Haptic safety-valve rate cap hit (%d/sec) -- dropping direction=%s",
            _HAPTIC_RATE_CAP_PER_SEC,
            direction,
        )
        return
    await haptic_manager.broadcast({"direction": direction})


# ---------------------------------------------------------------------------
# Camera status path: independent of hazards and haptics. Own connection
# manager, own endpoint. Broadcasts only on state transitions -- see
# camera_watchdog.py for why (it only ever returns an event on an actual
# change, never on steady state).
# ---------------------------------------------------------------------------

status_manager = ConnectionManager()


@app.websocket("/ws/status")
async def ws_status(websocket: WebSocket) -> None:
    await status_manager.connect(websocket)
    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        status_manager.disconnect(websocket)


async def broadcast_status(event: str, timestamp: float) -> None:
    """
    Called by status_loop.py whenever CameraWatchdog reports a state
    transition. Sends exactly {"event": ..., "timestamp": ...} -- nothing
    else -- to every connected Swift client.
    """
    await status_manager.broadcast({"event": event, "timestamp": timestamp})


# ---------------------------------------------------------------------------
# Demo/testing hook: lets the phone app fake a sensor event on demand.
# Forces a dip on the chosen mock ToF sensor, so the REAL haptic loop /
# thresholds / arbiter / narration pipeline all react exactly as they would
# to hardware -- nothing downstream is stubbed. For left/right (which the
# overhead-narration path doesn't cover), a matching fake camera detection
# is also queued so the event gets a plain-English Gemini narration too.
# ---------------------------------------------------------------------------

import random as _random

from fastapi import HTTPException

from pipeline import narration_queue as _narration_queue
from pipeline import tof_input as _tof_input
from pipeline.detection_input import capture_frame as _capture_frame

_SIM_DISTANCE_M = 0.5
_SIM_OBJECT_CLASSES = ("pole", "person", "bicycle", "chair")


@app.post("/simulate/tof/{direction}")
async def simulate_tof(direction: str) -> dict:
    if direction not in ("left", "right", "up"):
        raise HTTPException(status_code=400, detail="direction must be left, right, or up")

    _tof_input.force_dip(direction, distance_m=_SIM_DISTANCE_M)

    object_class = None
    if direction in ("left", "right"):
        # Random object class per tap so repeated simulations read as new
        # hazards to HazardThrottle's (object_class, direction) dedup and
        # still narrate instead of being cooldown-suppressed.
        object_class = _random.choice(_SIM_OBJECT_CLASSES)
        detection = {
            "timestamp": time.time(),
            "object_class": object_class,
            "direction": direction,
            "confidence": 0.95,
            "distance_m": _SIM_DISTANCE_M,
        }
        _narration_queue.push_nowait(
            {"source": "camera", "detection": detection, "frame": _capture_frame()}
        )

    logger.info("Simulated ToF event: direction=%s object_class=%s", direction, object_class)
    return {"ok": True, "direction": direction, "object_class": object_class}


def get_local_ip() -> str:
    """
    Best-effort discovery of this machine's LAN IP (not 127.0.0.1), since
    the Swift app on a phone connects over WiFi, not localhost. Opens a UDP
    socket to a public address without actually sending traffic, purely to
    ask the OS which local interface/IP would be used for outbound
    connections.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()
