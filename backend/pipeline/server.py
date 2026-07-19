"""
Stage 4: FastAPI app exposing the WebSocket endpoint the Swift app connects
to, plus a health check.

WebSocket contract (fixed -- the Swift app decodes exactly this shape, no
extra fields): {hazard_type, direction, urgency, spoken_description}.

/ws/hazards is bidirectional: besides broadcasting ambient hazard
narration (unchanged), it also receives on-demand voice questions from
the connected Swift client and replies on that same connection -- see
_handle_hazards_message() below.
"""

from __future__ import annotations

import asyncio
import collections
import json
import logging
import socket
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from pipeline import conversation_memory
from pipeline.detection_input import capture_frame
from pipeline.gemini_stage import answer_query

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
    # A crashed background task otherwise dies silently (its exception is
    # only surfaced if something awaits it, and nothing does) -- log it
    # loudly so a dead haptic/pipeline/status loop is visible in the
    # server terminal instead of just "haptics stopped working."
    def _log_crash(task: asyncio.Task) -> None:
        if not task.cancelled() and task.exception() is not None:
            logger.error("Background task crashed", exc_info=task.exception())
    for task in tasks:
        task.add_done_callback(_log_crash)
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
        # One lock per connection, guarding every send on that socket.
        # /ws/hazards now has two independent sources of outbound
        # messages on the same connection -- narration_worker.py's
        # ambient broadcast_hazard() (its own background task) and a
        # direct query reply from this connection's own receive loop
        # (see _handle_hazards_message()). Two tasks calling send() on one
        # raw WebSocket at the same time isn't safe, so every send funnels
        # through send_to() below, which serializes on this lock.
        self._locks: dict[WebSocket, asyncio.Lock] = {}

    def has_clients(self) -> bool:
        return bool(self._connections)

    async def connect(self, websocket: WebSocket) -> None:
        await websocket.accept()
        self._connections.append(websocket)
        self._locks[websocket] = asyncio.Lock()
        logger.info("Client connected (%d total)", len(self._connections))

    def disconnect(self, websocket: WebSocket) -> None:
        if websocket in self._connections:
            self._connections.remove(websocket)
        self._locks.pop(websocket, None)
        logger.info("Client disconnected (%d total)", len(self._connections))

    async def send_to(self, websocket: WebSocket, message: dict) -> None:
        """Sends to exactly one connection, serialized against any other
        concurrent send (e.g. an ambient broadcast) on that same socket."""
        lock = self._locks.get(websocket)
        if lock is None:
            return  # already disconnected
        async with lock:
            await websocket.send_json(message)

    async def broadcast(self, message: dict) -> None:
        # Iterate over a copy since a failed send mutates self._connections
        # via disconnect() during iteration.
        for websocket in list(self._connections):
            try:
                await self.send_to(websocket, message)
            except Exception as exc:  # noqa: BLE001 - a dead socket shouldn't kill the broadcast
                logger.warning("Failed to send to a client, dropping it: %s", exc)
                self.disconnect(websocket)


manager = ConnectionManager()


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


# "Hey Cane" on-demand voice Q&A rides on this same /ws/hazards connection
# (per the Swift app's existing architecture) rather than a separate REST
# call. Same fallback text gemini_stage.answer_query() uses internally for
# Gemini failures -- kept as its own constant here since the failures this
# guards against (Mongo, capture_frame) are outside answer_query() itself.
_VOICE_QUERY_FALLBACK_ANSWER = "Sorry, I couldn't process that right now."


async def _handle_hazards_message(websocket: WebSocket, raw: str) -> None:
    """
    Parses whatever text arrives on /ws/hazards. If it matches the voice
    query shape the Swift app actually sends --
    {"question": "...", "session_id": "..."} -- answers it and replies on
    THIS connection with {"answer": "..."}, matching CaneMessage.swift's
    CaneHazardChannelEvent decoder exactly (it checks for an "answer" key
    before anything else, so this flat shape needs no discriminator).

    Anything that isn't a well-formed query (bad JSON, wrong shape, or any
    other traffic) is silently ignored -- same as the original
    receive-only behavior, since this socket was never meant to validate
    or react to arbitrary input.
    """
    try:
        payload = json.loads(raw)
    except ValueError:
        return

    if not isinstance(payload, dict):
        return
    question = payload.get("question")
    session_id = payload.get("session_id")
    if not isinstance(question, str) or not isinstance(session_id, str):
        return

    # Conversation memory is best-effort: if Mongo is down/unconfigured the
    # user still gets a real answer — just without cross-question context —
    # instead of the fallback apology.
    recent_context = []
    try:
        recent_context = await conversation_memory.get_recent_context(session_id)
    except Exception as exc:  # noqa: BLE001 - answer without context rather than fail
        logger.warning("Conversation memory read failed (answering without context): %s", exc)

    try:
        # capture_frame() is now the real camera board (2026-07-19),
        # async, and can return None on failure (board unreachable,
        # timeout, bad response) -- raising here routes it through this
        # same except block below with a clear message, rather than
        # letting a None slip into answer_query() and fail with a
        # confusing Gemini/image-decoding error instead.
        frame = await capture_frame()
        if frame is None:
            raise RuntimeError("camera frame capture failed (board unreachable or bad response)")
        answer = await answer_query(frame, question, recent_context)
    except Exception as exc:  # noqa: BLE001 - a bad query must not kill the connection
        logger.error("Voice query handling failed, replying with fallback: %s", exc)
        answer = _VOICE_QUERY_FALLBACK_ANSWER
    else:
        try:
            await conversation_memory.save_exchange(session_id, question, answer)
        except Exception as exc:  # noqa: BLE001 - memory write failure shouldn't lose the answer
            logger.warning("Conversation memory save failed: %s", exc)

    try:
        await manager.send_to(websocket, {"answer": answer})
    except Exception as exc:  # noqa: BLE001 - a dead socket shouldn't crash the receive loop
        logger.warning("Failed to send voice answer, client likely disconnected: %s", exc)


@app.websocket("/ws/hazards")
async def ws_hazards(websocket: WebSocket) -> None:
    await manager.connect(websocket)
    try:
        while True:
            # Ambient hazard broadcasts (broadcast_hazard(), below) arrive
            # on this same connection from narration_worker.py's own
            # background task, entirely independent of this receive loop
            # -- awaiting a query here never blocks those sends, since
            # they don't go through this coroutine at all, and the
            # ConnectionManager lock (see send_to()) only serializes the
            # instant of actually writing to the socket, not the Gemini
            # call that produces the answer.
            raw = await websocket.receive_text()
            await _handle_hazards_message(websocket, raw)
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
        # capture_frame() is now the real camera board (2026-07-19) and
        # can return None on failure -- same "skip rather than push a
        # frameless event" handling as main.py's _process_detection().
        frame = await _capture_frame()
        if frame is None:
            logger.warning("Simulated ToF event: frame capture failed, skipping narration push")
        else:
            _narration_queue.push_nowait(
                {"source": "camera", "detection": detection, "frame": frame}
            )

    logger.info("Simulated ToF event: direction=%s object_class=%s", direction, object_class)
    return {"ok": True, "direction": direction, "object_class": object_class}


# ---------------------------------------------------------------------------
# SOS relay: sends real iMessage/SMS with zero user interaction by driving
# the Mac's Messages.app via AppleScript. iOS forbids apps from sending SMS
# silently, but macOS Messages is scriptable — and this server already runs
# on the Mac, so the phone just asks us to send. Recipients with iPhones get
# iMessage instantly; enabling Text Message Forwarding on the paired iPhone
# extends this to true SMS for non-iMessage numbers. macOS-only by nature.
# ---------------------------------------------------------------------------

import subprocess as _subprocess
import sys as _sys

_SEND_SCRIPT = (
    'on run {target, msg}\n'
    'tell application "Messages"\n'
    'send msg to participant target\n'
    'end tell\n'
    'end run'
)


def _send_via_messages_app(recipient: str, message: str):
    proc = _subprocess.run(
        ["osascript", "-e", _SEND_SCRIPT, recipient, message],
        capture_output=True, text=True, timeout=20,
    )
    err = proc.stderr.strip()
    return (proc.returncode == 0 and not err), (err or None)


@app.post("/sos")
async def sos_relay(payload: dict) -> dict:
    if _sys.platform != "darwin":
        raise HTTPException(status_code=501, detail="Messages relay only works on macOS")
    recipients = payload.get("recipients") or []
    message = payload.get("message") or ""
    if not recipients or not message:
        raise HTTPException(status_code=400, detail="recipients and message are required")

    results = []
    for recipient in recipients:
        try:
            ok, err = await asyncio.to_thread(_send_via_messages_app, recipient, message)
        except Exception as exc:  # noqa: BLE001 - report, don't crash the endpoint
            ok, err = False, str(exc)
        results.append({"to": recipient, "ok": ok, "error": err})
        logger.info("SOS relay to %s: %s%s", recipient, "sent" if ok else "FAILED",
                    f" ({err})" if err else "")

    sent = sum(1 for r in results if r["ok"])
    return {"sent": sent, "results": results}


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
