# Cane hazard pipeline

Four independent background tasks, all wired up in `pipeline/main.py`:

- **Camera detection path** (`run_pipeline`): real camera detection events
  (added 2026-07-19, see "Real camera detection events" below) -> ToF
  distance lookup -> filter -> real frame capture over HTTP (added
  2026-07-19, see "Real camera frame capture" below) -> pushes onto a
  shared narration queue. A capture failure (board unreachable, bad
  response) skips the push for that detection entirely rather than
  narrating a placeholder.
- **Haptic reflex path** (`run_haptic_loop`): ToF sensors -> threshold
  check -> immediate, unthrottled direction broadcast over `/ws/haptics`
  -- and, for overhead ("up") triggers only, *also* a fire-and-forget push
  onto the same narration queue (see "Overhead hazard narration" below).
- **Narration worker** (`run_narration_worker`): the single place both of
  the above meet -- pulls queued events, throttles, produces a spoken
  description (via Gemini for camera events, via a template for overhead
  ones), and broadcasts the result over `/ws/hazards`.
- **Camera status loop** (`run_status_loop`, added 2026-07-18): consumes a
  periodic camera heartbeat and broadcasts online/offline transitions over
  `/ws/status`, completely independent of the three paths above (see
  "Camera health monitoring" below).

`/ws/hazards` is also bidirectional (added 2026-07-19): besides the
ambient broadcasts above, it receives on-demand "Hey Cane" voice questions
from the connected client and replies on that same connection -- see
"On-demand Q&A" below. There's no separate task or endpoint for this; it's
handled inline in the same connection's receive loop.

Pipeline stages (see `pipeline/`):

1. **detection_input.py** -- filters raw detections (`should_escalate`),
   attaches ToF-sourced distance (`attach_distance`), and captures the
   current camera frame over HTTP (`capture_frame()`, added 2026-07-19,
   see "Real camera frame capture" below). `mock_detection_stream()` and
   `mock_capture_frame()` are both kept for `--simulate-crash` and
   hardware-less dev.
2. **camera_events.py** -- real camera detection events over UDP, added
   2026-07-19 (see "Real camera detection events" below); bridges a
   teammate's thread-driven `listen_events()` into the asyncio pipeline
   via `CameraEventBridge`.
3. **tof_input.py** -- real ToF (time-of-flight) hardware reads for three
   units (left/right/up), added 2026-07-19 (see "Real ToF hardware" below);
   the single interface to ToF hardware, called by both paths. The
   original mock is kept alongside as `mock_read_all_tof()` for tests and
   hardware-less development.
4. **narration_queue.py** -- the shared queue where camera-originated and
   overhead-ToF-originated events both land, consumed by
   `narration_worker.py`. `push_nowait()` never blocks and never raises.
5. **throttle.py** -- `HazardThrottle`: dedups an ongoing hazard, holds off
   re-narrating it for a cooldown window, bypasses that cooldown on genuinely
   new information (signature change or sharp worsening), and enforces a
   hard rate cap as a safety net for chaotic scenes. One shared instance is
   used for both narration origins.
6. **gemini_stage.py** -- sends the frame + detection to Gemini
   (`gemini-3.5-flash`) and parses the structured hazard JSON. Never called
   for overhead hazards (see below). Also holds `answer_query()`, a
   separate open-ended-question prompt/flow for "Hey Cane" (see below) --
   a different prompt and no JSON mode, but the same client/model and
   retry-then-fallback pattern as `analyze_hazard()`. Called from
   `server.py`'s `/ws/hazards` handler, not from a REST endpoint.
7. **narration_templates.py** -- fixed spoken-description templates for
   overhead hazards, picked by distance, no Gemini call involved.
8. **narration_worker.py** -- consumes `narration_queue`, runs the shared
   throttle, calls `gemini_stage` or `narration_templates` depending on
   event source, and broadcasts the result.
9. **haptic_trigger.py** -- `check_thresholds()`: which ToF directions
   currently read too close, with hysteresis (two thresholds, not a time
   delay) so sensor jitter around one distance can't flip a direction's
   state every poll cycle.
10. **haptic_loop.py** -- tight, independent polling loop driving the haptic
    reflex path; never imports `throttle.py` or `gemini_stage.py` (the
    narration_queue push for "up" triggers is fire-and-forget and adds no
    dependency on either).
11. **server.py** -- FastAPI app: `GET /health`, `WS /ws/hazards`
    (bidirectional -- broadcasts ambient hazards AND receives/answers
    on-demand voice questions), `WS /ws/haptics`, `WS /ws/status` -- each
    connection type with its own `ConnectionManager`, which now also holds
    a per-connection send lock (see "On-demand Q&A" below for why).
12. **heartbeat_input.py** -- mock periodic camera heartbeat, independent
    of detection events; the integration point for the real hardware
    heartbeat feed.
13. **camera_watchdog.py** -- `CameraWatchdog`: turns heartbeat activity
    (or silence) into online/offline transitions, firing an event only
    when the state actually changes.
14. **status_loop.py** -- consumes the heartbeat stream and independently
    polls for timeout, both driving one `CameraWatchdog`; never imports
    `throttle.py`, `gemini_stage.py`, `narration_queue.py`, `haptic_loop.py`,
    or `haptic_arbiter.py`.
15. **conversation_memory.py** -- MongoDB-backed conversation history for
    the "Hey Cane" on-demand Q&A feature (see below); the only module that
    talks to Mongo.
16. **main.py** -- wires all four background tasks together (the voice
    query path needs no task of its own -- it's handled inline in
    `/ws/hazards`'s existing receive loop).

## macOS / Linux setup

```bash
cd backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# then edit .env and paste your real key into GEMINI_API_KEY=
# and MONGODB_URI= -- same Atlas connection string vercel-backend/ uses
# (see vercel-backend/README.md if you need to create one). MONGODB_DB_NAME
# defaults to "caneos", matching vercel-backend's default.
```

## Running the server

```bash
source venv/bin/activate
python -m pipeline.main
```

On startup it prints your machine's LAN IP and the WebSocket URL, e.g.:

Health check:        http://192.168.1.23:8765/health
Swift app should connect to: ws://192.168.1.23:8765/ws/hazards

Use that IP (not `localhost`) in the Swift app's `Config.backendWebSocketURL`
-- the port (8765) already matches the placeholder there.

## Testing it

With the server running in one terminal, in another:

```bash
source venv/bin/activate
python test_client.py
```

This connects to `/ws/hazards` and pretty-prints every hazard message as it
arrives. You should see one roughly every few seconds in normal mock mode
(mock detections escalate somewhat randomly).

## Haptic reflex path (`/ws/haptics`)

A tight polling loop (`haptic_loop.py`, ~15Hz) reads the three real ToF
sensors (`tof_input.py` -- see "Real ToF hardware" below) and checks
thresholds (`haptic_trigger.py`), purely for low detection latency. What
sits between detection and the actual
`/ws/haptics` broadcast is `haptic_arbiter.HapticArbiter` (added
2026-07-18), which paces and prioritizes what actually gets sent -- the
message format itself is unchanged:

```json
{"direction": "left"}
```

**Threshold hysteresis (`haptic_trigger.py`, added 2026-07-18):** a
direction becomes triggered the instant its distance drops below
`TRIGGER_THRESHOLD_M` (0.75m) -- still immediate, no delay -- but only
clears once it rises back above the higher `CLEAR_THRESHOLD_M` (0.90m),
rather than clearing the moment a single reading crosses back over 0.75m.
This exists because a sensor reading jittering around one physical
object's real distance (e.g. wobbling between 0.7m and 0.85m) would
otherwise flip triggered/cleared on every single ~15Hz poll, making one
continuous hazard look like dozens of separate ones to everything
downstream. (`tof_input.mock_read_all_tof()`, kept alongside the real
implementation for tests/hardware-less dev, separately smooths its own
simulated dip readings -- one baseline distance per dip, jittered only
slightly, rather than a fresh independent draw every call -- to reduce how
often a dip's readings wander across a threshold in the first place; the
real hardware obviously isn't something we can "smooth," which is exactly
why hysteresis lives here rather than relying on the sensor being clean.)
It's a distance-based band, not a time-based debounce, so it doesn't delay
a genuinely new hazard's first trigger.

**Why pacing was needed:** broadcasting on every ~15Hz poll cycle is far
faster than the Apple Watch's Taptic Engine can physically play (each buzz
runs ~1.5-2s) -- it was overstimulating. `HapticArbiter` fixes that with
two rules, independent of `throttle.py`/`gemini_stage.py`/`narration_worker.py`
(same as the rest of this path):

- **Pacing, per direction:** the instant a direction transitions from
  clear to triggered, it broadcasts immediately (edge-triggered). While it
  stays triggered, it re-broadcasts at most once every
  `haptic_arbiter.REMINDER_INTERVAL_SECONDS` (4s by default, measured
  start-to-start). The instant it clears, its state fully resets -- a
  later re-trigger is immediate again, never still "cooling down."
- **Priority arbitration:** if multiple directions are triggered at once,
  only the closest broadcasts. That direction **keeps** priority for as
  long as it stays triggered, even if another direction becomes closer in
  the meantime -- re-comparing distances every cycle would flicker the
  winner back and forth if two hazards sit at near-equal distance and
  jitter, which is worse than briefly favoring a slightly-stale pick.
  Priority is only re-evaluated once the current winner clears, at which
  point the next-closest still-triggered direction is promoted and
  broadcasts **immediately** (no reminder delay) -- it was suppressed the
  whole time, so the user was never actually warned about it yet.

`haptic_loop.py`'s narration push for "up" triggers (see "Overhead hazard
narration" below) is unaffected by any of this -- it still fires on every
cycle "up" is triggered, since that path has its own separate throttle in
`narration_worker.py`.

`server.py`'s ~20 msgs/sec safety valve is unchanged and still purely a
runaway-bug guard; with arbitration in place it's now even less likely to
ever bind, since normal pacing tops out far below it on its own.

Try it with:

```bash
source venv/bin/activate
python test_haptic_client.py
```

You should see one `{"direction": "..."}` message the instant a sensor
crosses threshold, then at most one more every ~4s while it stays close
(not a burst on every poll tick), as the mock ToF sensors simulate
something passing close by.

## Overhead hazard narration (no Gemini call)

The camera is aimed forward at cane/chest height -- it has no view of
overhead space, so an "up" ToF trigger has no useful photo to hand Gemini.
Rather than send a vision call with nothing relevant to look at,
`haptic_loop.py` pushes a `{"source": "tof_up", "distance_m": ...}` event
onto `narration_queue` (fire-and-forget, alongside its unchanged immediate
`/ws/haptics` buzz), and `narration_worker.py` turns that into a hazard
using a fixed template (`narration_templates.build_up_hazard()`) instead of
calling `gemini_stage.analyze_hazard()`.

Both origins -- camera detections and overhead triggers -- flow through the
*same* `HazardThrottle` instance and the *same* `/ws/hazards` broadcast
from `narration_worker.py`, so an overhead hazard dedups/cools down exactly
like any other, just under its own fixed signature
(`("overhead_obstacle", "up")`). The throttle check happens *before*
Gemini is called for camera events (not after) -- see
`narration_worker.py`'s module docstring for why that ordering matters
(bounding actual Gemini call volume, not just broadcast volume, and keeping
dedup keyed on stable fields rather than Gemini's freely-worded output).

**Contract change for the Swift consumer:** `/ws/hazards`'s `direction`
field can now be `"up"` in addition to `"left" | "center" | "right"`. This
is intentional, not a bug -- overhead hazards are a real, distinct
narration case. Whatever decodes `/ws/hazards` messages needs to accept a
fourth `direction` value.

## Camera health monitoring (`/ws/status`)

Without this, "camera saw nothing hazardous" and "camera pipeline crashed"
look identical downstream -- both just mean no hazard messages arrive. To
tell them apart, the camera process is expected to push a periodic
heartbeat, independent of whatever it does or doesn't detect:

```json
{"status": "ok", "timestamp": 1700000000}
```

or, if it can detect its own failure:

```json
{"status": "error", "detail": "...", "timestamp": 1700000000}
```

`camera_watchdog.CameraWatchdog` turns that (or its absence) into
online/offline state, and `/ws/status` broadcasts **only on actual
transitions** -- same "don't spam" principle as everything else in this
project:

```json
{"event": "camera_offline", "timestamp": 1700000000}
{"event": "camera_restored", "timestamp": 1700000000}
```

Two independent ways a failure is detected:

- **Explicit**: the camera reports `{"status": "error", ...}` itself --
  `camera_offline` fires immediately, no waiting.
- **Implicit (silence)**: the camera stops sending heartbeats entirely
  (crash, hang, unplugged) -- this is only detectable by the *absence* of
  activity, so `status_loop.py` polls `CameraWatchdog.check_timeout()`
  every second, independent of whether a heartbeat ever arrives again. If
  more than `camera_watchdog.WATCHDOG_TIMEOUT_SECONDS` (12s, ~2.4x the 5s
  heartbeat interval) passes with nothing heard, `camera_offline` fires.
  A single `ok` heartbeat afterward fires `camera_restored`.

**This path is fully independent** of the hazard/narration path and the
haptic path -- no imports between them, no shared state. In particular,
**`/ws/haptics` keeps working completely independently of camera status**:
a camera failure degrades the system from "buzz + spoken context" down to
"buzz only," never down to nothing, since the ToF-driven haptic reflex
never depended on the camera to begin with. That's a real property of this
architecture worth stating plainly, not an accident.

Try it with:

```bash
source venv/bin/activate
python test_status_client.py
```

You should see **nothing** print during normal operation -- this channel
is silent except on actual transitions. To exercise it, from a Python
shell with the server's venv active (or by temporarily calling it from
code): `from pipeline.heartbeat_input import simulate_camera_failure;
simulate_camera_failure(20.0)` stops the mock heartbeat entirely for 20s,
simulating a real crash. After ~12s of that silence you should see exactly
one `camera_offline` event, then exactly one `camera_restored` once
heartbeats resume -- not a flood of either. `simulate_camera_error()` is
the same idea for testing the explicit-error path instead of silence.

**Integration point**: `pipeline/heartbeat_input.py`, replace
`mock_heartbeat_stream()` with an async generator reading the real
hardware's heartbeat channel, yielding the same
`{"status": "ok"|"error", "timestamp": ...}` shape.

## On-demand Q&A ("Hey Cane", over `/ws/hazards`)

A Swift teammate handles wake-word detection ("Hey Cane"), speech-to-text,
and speaking the final answer via ElevenLabs. This backend's job is just
the middle of that pipeline: given a question, answer it about the
current scene.

**This rides on the existing `/ws/hazards` WebSocket connection, not a
separate endpoint** (changed 2026-07-19 -- it was originally a standalone
`POST /query` REST endpoint, but the Swift app's actual architecture sends
voice questions and expects answers back over the same socket it's
already holding open for ambient hazard narration, so the backend now
matches that instead of requiring a second connection). `/ws/hazards` is
bidirectional: it still broadcasts ambient hazard JSON exactly as before
(unaffected), and it *also* reads incoming text frames, answering any that
match the query shape:

```
Swift app sends, over the open /ws/hazards connection:
{"question": "what's around me right now?", "session_id": "user_a1b2c3d4e5f6"}

Backend replies on that SAME connection:
{"answer": "You're in a hallway with a door open on your right and a chair a few feet ahead."}
```

`session_id` is whatever stable per-install identifier the Swift app
generates and persists (no cross-session memory -- context is scoped
entirely by this value). Anything that arrives on `/ws/hazards` that
*isn't* this exact shape (bad JSON, unrelated fields, or anything else) is
silently ignored, same as the connection's original disconnect-detection-only
behavior for non-query traffic.

What happens per query (`server._handle_hazards_message()`):
`conversation_memory.get_recent_context()` pulls that session's last few
exchanges -> `detection_input.capture_frame()` grabs the current frame
(same function the hazard path already uses, not duplicated) ->
`gemini_stage.answer_query()` sends the frame + question + context to
Gemini with an open-ended prompt (different from `analyze_hazard()`'s
structured hazard-JSON one -- no fixed response shape, no JSON mode, just
a natural-language answer meant to be read aloud) ->
`conversation_memory.save_exchange()` persists the new exchange -> the
answer is sent back directly to the connection that asked, not broadcast
to every connected client. Any failure anywhere in that chain (Gemini,
Mongo, frame capture) is caught and replies with a fallback answer instead
of raising -- a bad query must never kill the WebSocket connection.

**Concurrency note**: `/ws/hazards` now has two independent sources of
outbound messages on one connection -- `narration_worker.py`'s ambient
`broadcast_hazard()` (its own background task) and a direct query reply
from that connection's own receive loop. Two tasks calling `send()` on one
raw WebSocket at the same time isn't safe, so `ConnectionManager` now
holds a per-connection `asyncio.Lock`, and every send (broadcast or direct
reply) goes through `ConnectionManager.send_to()`, which serializes on it.
This only serializes the instant of writing to the socket, not the Gemini
call that produces the answer -- an in-flight query never blocks or delays
an ambient hazard broadcast to *other* connections, or to this one once
the lock is free.

**Fully independent of the throttle/narration path**: no
`HazardThrottle`, no `narration_queue`, no dedup or cooldown of any kind.
Every explicit question gets answered -- suppression only makes sense for
ongoing ambient hazard narration the user didn't ask for, not for
something they just asked out loud.

**Conversation memory lives in MongoDB now**, in the *same* Atlas
database `vercel-backend/` already uses for contacts/incidents (see
`conversation_memory.py`'s module docstring for why this is the same
database but necessarily a separate client -- Node.js/Vercel and this
Python backend are different processes/languages, so they can't literally
share a connection object, only the same `MONGODB_URI`/`MONGODB_DB_NAME`).
A new `conversations` collection stores only explicit Q&A exchanges
(`session_id`, `question`, `answer`, `timestamp`) -- ambient hazard
narrations are never written here.

**Manual test path**: with the server running, connect `test_client.py`
(it already listens on `/ws/hazards`) and, separately, send a question
over that same connection -- e.g. with `websockets` in a Python shell:

```python
import asyncio, websockets, json

async def ask():
    async with websockets.connect("ws://localhost:8765/ws/hazards") as ws:
        await ws.send(json.dumps({"question": "what is in front of me?", "session_id": "test-session-1"}))
        print(await ws.recv())

asyncio.run(ask())
```

You should get back `{"answer": "..."}` with no prior context (a new
`session_id`). Run it again with the *same* `session_id` and the first
exchange should now be part of the context Gemini sees -- add a temporary
`logger.info(prompt)` in `gemini_stage._build_query_prompt()` (or right
before the Gemini call) if you want to see the assembled prompt directly
while verifying this. While a question is in flight, `test_client.py`
should keep receiving any ambient hazard broadcasts normally, unaffected.

## Testing the throttle specifically

Unit tests (fast, no network, no real time delays -- uses a fake clock):

```bash
source venv/bin/activate
pytest
```

To see the throttling behave correctly against a realistic sustained
hazard, run the server in crash-simulation mode:

```bash
python -m pipeline.main --simulate-crash
```

(or set `SIMULATE_CRASH=true` as an environment variable instead of the
flag). This makes `mock_detection_stream` fire rapid, jittery detections of
roughly the same object/direction for about 2 minutes -- watch
`test_client.py`'s output and you should see narrations arrive only every
~8 seconds (the cooldown), or immediately if a detection jumps to a
different object/direction or the distance drops sharply, but never more
often than every ~3 seconds (the hard rate cap) even during the occasional
injected multi-object chaos.

## Distance now comes from ToF, not the camera

The OAK-1-AF camera has no depth perception, so a raw detection no longer
carries `distance_m` at all -- both `mock_detection_stream()` and the real
camera feed (`camera_events.py`, added 2026-07-19) only yield
`{timestamp, object_class, direction, confidence}`. `distance_m` is
attached separately, at detection-time, by `detection_input.attach_distance()`,
which looks up the current ToF reading for that detection's direction
(`"left"`/`"right"` map directly, `"center"` uses whichever of left/right
is closer). `main.py`'s pipeline calls `attach_distance()` before
`should_escalate()` -- `should_escalate()` itself still just reads
`detection["distance_m"]`, it just now requires that field to have already
been attached.

## Real ToF hardware (added 2026-07-19)

`pipeline/tof_input.py`'s `read_all_tof()` is now a real hardware read, not
a mock -- provided by a teammate, integrated as-is (her HTTP-polling logic
is unmodified): `requests.Session().get(f"http://{BOARD_IP}:8080/tof",
timeout=0.5).json()`, returning
`{"left": 2.1, "right": 3.4, "up": None}` in meters, where `None` means
"no reading for that direction" (sensor not wired up, or hasn't reported
since startup). `BOARD_IP` (`172.20.10.2`) is hardcoded to match her board
exactly -- it's tied to the specific physical hardware on her hotspot
network, not a per-deployment config value, so there's no env var for it.

**Async wrapping**: her read is a blocking synchronous HTTP call, and it's
polled from `haptic_loop.py`'s asyncio loop at ~15Hz. Calling it directly
would freeze the *entire* event loop -- every WebSocket, every background
task, not just the haptic loop -- for up to her 0.5s timeout, on every
single poll. `read_all_tof()` is now `async def`, wrapping the blocking
call in `asyncio.to_thread()` so it runs off the event loop entirely.
Every caller awaits it now: `haptic_loop.py` and
`detection_input.attach_distance()`. `tests/test_tof_input.py` proves this
empirically (not just by code inspection) -- it patches in an
artificially slow read and confirms a concurrent counter coroutine keeps
ticking throughout, rather than trusting that `asyncio.to_thread()` was
used correctly.

**None handling, end to end**: any of the three distances can be `None`.
- `haptic_trigger.check_thresholds()` treats `None` as "not triggered,"
  never compared against a threshold (which would raise) and never
  treated as `0` or otherwise falsely close.
- `detection_input.attach_distance()`: a direct left/right mapping passes
  `None` straight through as "distance unknown." For `"center"` (min of
  left/right), if exactly one side is `None` the other (known) value is
  used; if both are `None`, the result is also `None`, never a fabricated
  number.
- `detection_input.should_escalate()` never escalates on an unknown
  (`None`) distance -- escalating drives a real Gemini call and, via the
  throttle, a spoken narration, and there's no real reading to justify
  "this is close" with an unknown distance. The safer default is to not
  escalate; nothing is lost long-term, since the next detection for the
  same object is evaluated fresh once a real reading comes in.

**The original mock is kept, not deleted** -- `tof_input.mock_read_all_tof()`
(also `async def`, so it's a drop-in swap) -- for tests and any
hardware-less development. Nothing in the active pipeline calls it anymore;
import and use it explicitly if the real board isn't reachable.

**Known stale side effect**: `server.py`'s `/simulate/tof/{direction}`
demo endpoint and `tof_input.force_dip()` only manipulate
`mock_read_all_tof()`'s internal state. Now that the active pipeline calls
the real `read_all_tof()` instead, `/simulate/tof` no longer has any
effect on live haptic/narration behavior -- it wasn't touched in this
change (out of scope), but be aware it's now a no-op for its original
purpose until/unless that endpoint is updated separately. (Its call to
`capture_frame()` *was* touched during the 2026-07-19 frame-capture work,
purely to keep it from crashing now that `capture_frame()` is `async def`
-- see "Real camera frame capture" below -- it still doesn't drive real
ToF behavior.)

**Manual test path**: with `BOARD_IP` reachable (on her hotspot), run the
server and `test_haptic_client.py` as usual -- you should see real
left/right/up readings driving haptic behavior instead of simulated dips.
If "up" isn't wired up yet, confirm its `None` reading correctly means
"up" never triggers, without affecting left/right or crashing anything
else. If the board is unreachable entirely, every reading will be `None`
(her code's own fallback) -- confirm haptics simply stay quiet rather than
erroring.

## Real camera detection events (added 2026-07-19)

`pipeline/camera_events.py`'s `listen_events()` is a teammate's code,
integrated unmodified: a daemon thread listening for detection events over
UDP on `EVENT_PORT` (5005, same board as ToF's `BOARD_IP`, `172.20.10.2`,
different port), calling a callback once per event --
`{"timestamp": ..., "object_class": ..., "direction": ..., "confidence": ...}`.

**The thread-to-asyncio bridge**: her callback fires on her own background
thread, not the event loop's thread. `asyncio.Queue` isn't thread-safe, so
`CameraEventBridge` can't just push into it directly from that callback --
`_on_event()` validates the event, then hands the actual queue push to the
event loop via `loop.call_soon_threadsafe()`, which is exactly what
that API exists for (scheduling a callback to run safely on the loop's own
thread, callable from any other thread). This is a different problem than
`tof_input.py`'s `asyncio.to_thread()` wrapping -- that's a one-shot
blocking call wrapped fresh per poll; this is a long-lived background
thread pushing events whenever they arrive, so the bridge is a persistent
queue fed via `call_soon_threadsafe()`, not a per-call wrapper.
`tests/test_camera_events.py` proves the cross-thread handoff with a real
`threading.Thread`, not just a same-thread call.

**Defensive validation**: `is_valid_detection()` checks all four expected
keys are present and `direction` is one of `left`/`center`/`right` *before*
anything is queued -- a malformed event (missing key, garbage direction,
non-dict payload) is logged and dropped, never reaching
`attach_distance()`/`should_escalate()`, which assume well-formed input and
would otherwise crash on it.

**`mock_detection_stream()` is kept, not deleted** -- it's still the
active source when `--simulate-crash`/`SIMULATE_CRASH` is set, so
`HazardThrottle`'s chaotic-scene cooldown/rate-cap behavior can still be
demoed/verified on demand without needing the real hardware to misbehave
on cue (same reasoning `tof_input.mock_read_all_tof()` is kept for). By
default (no `--simulate-crash`), `CameraEventBridge` is the active source.

**Manual test path**: with her camera process running and reachable, run
the server (no flags) and watch `test_client.py` on `/ws/hazards` -- real
detection events should now flow through `attach_distance()` ->
`should_escalate()` -> `capture_frame()` -> `narration_queue`, ending in a
real Gemini call analyzing both real detection metadata and a real camera
frame (see "Real camera frame capture" below).

Without her hardware physically present, you can still exercise the real
UDP path end-to-end (not just the unit tests) by sending a packet shaped
like her event from a second terminal:

```python
import socket, json, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
event = {"timestamp": time.time(), "object_class": "person", "direction": "center", "confidence": 0.92}
s.sendto(json.dumps(event).encode(), ("127.0.0.1", 5005))
```

This is genuinely useful, not just a formality -- it's how the 2026-07-19
integration itself was verified live in an environment where neither her
ToF board nor her camera board was reachable: the packet arrives over a
real socket, gets validated and queued by `CameraEventBridge`, then (with
the ToF board unreachable, so distance comes back `None`) correctly falls
through `should_escalate()` without escalating -- no crash, no spurious
broadcast, confirming the whole chain rather than just each piece in
isolation. With a reachable ToF board giving a real close-enough reading,
the same packet would carry all the way through to a real Gemini call and
an actual `/ws/hazards` broadcast.

## Real camera frame capture (added 2026-07-19)

`pipeline/detection_input.py`'s `capture_frame()` is now a real HTTP grab
from a teammate's camera board, not the solid-color Pillow placeholder:
`requests.Session().get(f"http://{BOARD_IP}:{FRAME_PORT}/frame",
timeout=FRAME_TIMEOUT_S).content`, returning raw JPEG bytes.
`BOARD_IP` (`172.20.10.2`) is the same physical board as ToF and the UDP
detection events, just a different port (`FRAME_PORT = 8090`) -- hardcoded
the same way, for the same reason: it's tied to specific hardware on her
hotspot, not per-deployment config. `FRAME_TIMEOUT_S` is `3.0`.

**Async wrapping**: same pattern as `tof_input.read_all_tof()` -- the HTTP
GET is a blocking synchronous call, so `capture_frame()` is `async def`,
wrapping the blocking grab in `asyncio.to_thread()` so it never freezes
the event loop while waiting on the board.

**None on any failure**: `capture_frame()` returns `None` (never raises)
if the request times out, the connection fails, the response status isn't
200, the body is empty, or the bytes don't decode as a valid image
(checked via `PIL.Image.verify()`). Callers must treat `None` as "no
frame available this cycle," not an error to propagate.

**Every call site now awaits and handles `None`** -- there were three,
not the one originally assumed:
- `main.py`'s `_process_detection()`: the actual capture point in the live
  pipeline. A `None` frame logs a warning and skips pushing that
  detection onto `narration_queue` entirely -- no Gemini call, no
  narration, no broadcast, but processing continues normally for the next
  detection.
- `narration_worker.py`'s camera-event branch: a defensive second check
  (not reachable in the current flow, since `main.py` already filters
  `None` frames before they're queued, but kept in case that ever
  changes) -- skips the Gemini call and logs rather than passing `None`
  as an image.
- `server.py`'s on-demand "Hey Cane" query handler and the
  `/simulate/tof/{direction}` demo endpoint both also call
  `capture_frame()` directly. Both were missed by the original task
  description (which assumed only `narration_worker.py` needed updating)
  and would have broken the moment `capture_frame()` became `async def`
  -- an unawaited coroutine either raises `TypeError` (query handler,
  which now falls back to the generic fallback answer on a `None` frame)
  or gets pushed as a corrupt "frame" value (simulate endpoint, which now
  skips the narration push on `None` instead).

`mock_capture_frame()` is kept, not deleted, for tests and hardware-less
dev -- same convention as `mock_read_all_tof()`/`mock_detection_stream()`.

**Manual test path**: with `BOARD_IP` reachable on port `FRAME_PORT`, run
the server and drive a detection through (real camera events, or the UDP
test packet shown above) -- Gemini should now receive a real frame and
`spoken_description` should reflect the actual scene rather than a
solid-gray placeholder. With the board unreachable, confirm detections are
still processed but no narration is produced for them (skipped, not
crashed), and that `/ws/hazards` and `/ws/status` keep working normally
throughout.

## Known mismatch with the current Swift app (flag for your teammate)

The WebSocket payload sent here is the flat contract as originally agreed:

```json
{"hazard_type": "...", "direction": "...", "urgency": "...", "spoken_description": "..."}
```

The Swift code currently in `swift/CaneMessage.swift` decodes a different,
wrapped shape (`{"type": "hazard", ...}` / `{"type": "scene_description", ...}`)
with a non-optional `type` field -- as written, it will silently fail to
decode this pipeline's messages (the decode is wrapped in `try?`, so nothing
crashes, the message just never arrives). `CaneMessage.swift` needs a small
update to decode the flat shape.

Separately, the **narration** path's `direction` uses
`"left" | "center" | "right" | "up"` (the last added 2026-07-18 for
overhead hazards -- see "Overhead hazard narration" above), but
`PhoneSessionManager.HapticDirection` on the Swift side only recognizes
`left | right | up | down` -- a `"center"` value won't map to a haptic and
will silently no-op if anything still routes narration output to that enum.

That said, the new `/ws/haptics` path (added 2026-07-18) should make this
moot for actual haptics: it broadcasts `{"direction": "left"|"right"|"up"}`
directly off ToF sensor thresholds, matching `HapticDirection`'s vocabulary
exactly (`down` just isn't produced -- there's no downward-facing ToF unit).
Point the Watch haptic code at `/ws/haptics` instead of deriving haptics
from `/ws/hazards`, and the direction-vocabulary mismatch and the
haptics-coupled-to-narration issue both go away in one move.