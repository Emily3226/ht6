"""
Stage 4: FastAPI app exposing the WebSocket endpoint the Swift app connects
to, plus a health check.

WebSocket contract (fixed -- the Swift app decodes exactly this shape, no
extra fields): {hazard_type, direction, urgency, spoken_description}.
"""

from __future__ import annotations

import asyncio
import logging
import socket
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

logger = logging.getLogger(__name__)

# Default port matches the placeholder already hardcoded in the Swift app's
# Config.swift (ws://<ip>:8765) -- only the IP needs updating there, not the
# port, once this server is running on your machine.
DEFAULT_PORT = 8765


@asynccontextmanager
async def lifespan(app: FastAPI):
    # main.py sets app.state.on_startup (a zero-arg async callable) before
    # calling uvicorn.run(), so this stays free of any main.py-specific
    # pipeline wiring -- server.py only knows "run this coroutine as a
    # background task while the app is up, if one was provided."
    startup_hook = getattr(app.state, "on_startup", None)
    task = asyncio.create_task(startup_hook()) if startup_hook is not None else None
    try:
        yield
    finally:
        if task is not None:
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
