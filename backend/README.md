# Cane hazard pipeline

Four independent background tasks, all wired up in `pipeline/main.py`:

- **Camera detection path** (`run_pipeline`): camera detection -> ToF
  distance lookup -> filter -> pushes onto a shared narration queue.
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

Pipeline stages (see `pipeline/`):

1. **detection_input.py** -- filters raw detections (`should_escalate`),
   attaches ToF-sourced distance (`attach_distance`), and provides the mock
   detection/frame sources for now.
2. **tof_input.py** -- mock ToF (time-of-flight) sensor reads for three
   units (left/right/up); the single shared integration point for real ToF
   hardware, called by both paths.
3. **narration_queue.py** -- the shared queue where camera-originated and
   overhead-ToF-originated events both land, consumed by
   `narration_worker.py`. `push_nowait()` never blocks and never raises.
4. **throttle.py** -- `HazardThrottle`: dedups an ongoing hazard, holds off
   re-narrating it for a cooldown window, bypasses that cooldown on genuinely
   new information (signature change or sharp worsening), and enforces a
   hard rate cap as a safety net for chaotic scenes. One shared instance is
   used for both narration origins.
5. **gemini_stage.py** -- sends the frame + detection to Gemini
   (`gemini-3.5-flash`) and parses the structured hazard JSON. Never called
   for overhead hazards (see below).
6. **narration_templates.py** -- fixed spoken-description templates for
   overhead hazards, picked by distance, no Gemini call involved.
7. **narration_worker.py** -- consumes `narration_queue`, runs the shared
   throttle, calls `gemini_stage` or `narration_templates` depending on
   event source, and broadcasts the result.
8. **haptic_trigger.py** -- `check_thresholds()`: which ToF directions
   currently read too close, with hysteresis (two thresholds, not a time
   delay) so sensor jitter around one distance can't flip a direction's
   state every poll cycle.
9. **haptic_loop.py** -- tight, independent polling loop driving the haptic
   reflex path; never imports `throttle.py` or `gemini_stage.py` (the
   narration_queue push for "up" triggers is fire-and-forget and adds no
   dependency on either).
10. **server.py** -- FastAPI app: `GET /health`, `WS /ws/hazards`,
    `WS /ws/haptics`, and `WS /ws/status`, each with their own connection
    manager.
11. **heartbeat_input.py** -- mock periodic camera heartbeat, independent
    of detection events; the integration point for the real hardware
    heartbeat feed.
12. **camera_watchdog.py** -- `CameraWatchdog`: turns heartbeat activity
    (or silence) into online/offline transitions, firing an event only
    when the state actually changes.
13. **status_loop.py** -- consumes the heartbeat stream and independently
    polls for timeout, both driving one `CameraWatchdog`; never imports
    `throttle.py`, `gemini_stage.py`, `narration_queue.py`, `haptic_loop.py`,
    or `haptic_arbiter.py`.
14. **main.py** -- wires all four background tasks together.

## macOS / Linux setup

```bash
cd backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# then edit .env and paste your real key into GEMINI_API_KEY=
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

A tight polling loop (`haptic_loop.py`, ~15Hz) reads the three mock ToF
sensors (`tof_input.py`) and checks thresholds (`haptic_trigger.py`), purely
for low detection latency. What sits between detection and the actual
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
downstream. `tof_input.py` separately smooths its own mock dip readings
(one baseline distance per dip, jittered only slightly, rather than a
fresh independent draw every call) to reduce how often a dip's readings
wander across a threshold in the first place -- but hysteresis is what
actually closes the remaining gap, since even smoothed readings can
occasionally land close enough to a threshold to cross it. It's a
distance-based band, not a time-based debounce, so it doesn't delay a
genuinely new hazard's first trigger.

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
carries `distance_m` at all -- `mock_detection_stream()` (and the real
camera feed, eventually) only yields
`{timestamp, object_class, direction, confidence}`. `distance_m` is
attached separately, at detection-time, by `detection_input.attach_distance()`,
which looks up the current ToF reading for that detection's direction
(`"left"`/`"right"` map directly, `"center"` uses whichever of left/right
is closer). `main.py`'s pipeline calls `attach_distance()` before
`should_escalate()` -- `should_escalate()` itself still just reads
`detection["distance_m"]`, it just now requires that field to have already
been attached.

## Integration points for teammates

- **Real ToF hardware**: `pipeline/tof_input.py`, replace the body of
  `read_all_tof()` with the real sensor read. It's the *only* interface to
  ToF hardware -- both the haptic loop and the camera path
  (`attach_distance()`) call through it, so nothing downstream needs to
  change as long as the return shape (`{"left": float, "right": float, "up": float}`)
  stays the same.
- **Real camera detection feed**: `pipeline/detection_input.py`, replace
  `mock_detection_stream()` with a generator/async-generator from the real
  OAK-1-AF pipeline, yielding dicts shaped
  `{timestamp, object_class, direction, confidence}` (no distance -- see
  above). Wire it into `pipeline/main.py`'s `run_pipeline()` in place of
  the mock stream.
- **Real camera frame**: `pipeline/detection_input.py`, replace
  `capture_frame()` with the real frame grab; keep the `-> bytes` (JPEG)
  signature so nothing downstream needs to change.

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