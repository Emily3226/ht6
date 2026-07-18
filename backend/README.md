# Cane hazard pipeline

Camera detection -> Gemini vision analysis -> hazard JSON, broadcast to the
Swift app over a local WebSocket.

Pipeline stages (see `pipeline/`):

1. **detection_input.py** -- filters raw detections (`should_escalate`) and
   provides the mock detection/frame sources for now.
2. **throttle.py** -- `HazardThrottle`: dedups an ongoing hazard, holds off
   re-narrating it for a cooldown window, bypasses that cooldown on genuinely
   new information (signature change or sharp worsening), and enforces a
   hard rate cap as a safety net for chaotic scenes.
3. **gemini_stage.py** -- sends the frame + detection to Gemini
   (`gemini-3.5-flash`) and parses the structured hazard JSON.
4. **server.py** -- FastAPI app: `GET /health` and `WS /ws/hazards`, which
   broadcasts hazard JSON to every connected client.
5. **main.py** -- wires all of the above together and runs the pipeline as
   a background task alongside uvicorn.

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

## Integration points for teammates

- **Real hardware feed**: `pipeline/detection_input.py`, replace
  `mock_detection_stream()` with a generator/async-generator from the real
  OAK-1-AF + ToF pipeline, yielding dicts with the same shape:
  `{timestamp, object_class, direction, confidence, distance_m}`. Wire it
  into `pipeline/main.py`'s `run_pipeline()` in place of the mock stream.
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

Separately, `direction` here uses `"left" | "center" | "right"` (matching
the hardware detection contract and the Gemini prompt), but
`PhoneSessionManager.HapticDirection` on the Swift side only recognizes
`left | right | up | down` -- a `"center"` value won't map to a haptic and
will silently no-op. Worth reconciling directly with whoever owns the Watch
haptic code, since haptics are meant to be a separate, unthrottled path off
raw sensor data rather than driven by this pipeline's output anyway.