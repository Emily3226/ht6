"""
Stage 3: send the captured frame + triggering detection to Gemini, get back
a structured hazard description.

Uses gemini-2.5-flash: it's the fastest/cheapest model in the current
multimodal lineup ("fastest and most budget-friendly multimodal model" per
Google's own model docs as of mid-2026), which matters here since this call
sits in the latency-critical path between "hazard detected" and "user hears
about it." Swap MODEL_NAME below if a faster/cheaper option becomes
available later.
"""

from __future__ import annotations

import json
import logging
import re

from google import genai
from google.genai import types

logger = logging.getLogger(__name__)

MODEL_NAME = "gemini-3.1-flash-lite"

_FALLBACK_RESULT = {
    "hazard_type": "unknown",
    "direction": "center",
    "urgency": "low",
    "spoken_description": "Possible obstacle ahead, please proceed with caution.",
}

_MARKDOWN_FENCE_RE = re.compile(r"^```(?:json)?\s*|\s*```$", re.IGNORECASE | re.MULTILINE)

# Created lazily on first use (not at import time) so importing this module
# doesn't require GEMINI_API_KEY to already be set -- useful for running
# tests that never touch the network. genai.Client() picks up the key from
# the GEMINI_API_KEY env var automatically.
_client: genai.Client | None = None


def _get_client() -> "genai.Client":
    global _client
    if _client is None:
        _client = genai.Client()
    return _client

_PROMPT_TEMPLATE = """\
You are a hazard-detection assistant for a blind cane user. You are given a \
camera frame and the sensor detection that triggered this analysis.

Triggering detection:
- object_class: {object_class}
- direction: {direction}
- distance_m: {distance_m}

Look at the image and describe the hazard as it would matter to someone who \
cannot see it. Use "urgent" only for a life-threatening emergency happening \
right now, at the user's feet (e.g. an about-to-collide vehicle, a fall/drop \
already underway) -- this should be rare. Respond with ONLY a JSON object, \
no markdown code fences, no extra commentary, in exactly this shape:
{{
  "hazard_type": string,
  "direction": "left" | "center" | "right",
  "urgency": "low" | "medium" | "high" | "urgent",
  "spoken_description": string (under 15 words, a natural sentence ready for text-to-speech)
}}
"""


def _build_prompt(detection: dict) -> str:
    return _PROMPT_TEMPLATE.format(
        object_class=detection.get("object_class", "unknown"),
        direction=detection.get("direction", "unknown"),
        distance_m=detection.get("distance_m", "unknown"),
    )


# Distance beyond which we don't trust an "urgent" label regardless of what
# the model returned. Tighter than the "high" gate below on purpose --
# "urgent" is the only tier that can trigger the SOS countdown, so this
# threshold is deliberately conservative (closer than the "high" gate).
_URGENT_MAX_DISTANCE_M = 1.0

# hazard_type / object_class substrings that are allowed to reach "urgent".
# This is intentionally a short, conservative allow-list rather than a
# deny-list: if a hazard doesn't clearly match one of these life-threatening
# categories, it gets downgraded even if the model was confident. Matched
# case-insensitively as a substring against both hazard_type (Gemini's own
# free-text label) and the triggering detection's object_class, since
# either one naming a car/stairs/drop-off is good enough evidence.
_URGENT_ALLOWED_TYPE_SUBSTRINGS = (
    "car", "vehicle", "truck", "bus", "motorcycle", "bike", "bicycle",
    "stair", "step", "drop", "hole", "cliff", "ledge", "curb", "pit",
)


def _mentions_urgent_type(*texts: str) -> bool:
    haystack = " ".join(t.lower() for t in texts if t)
    return any(needle in haystack for needle in _URGENT_ALLOWED_TYPE_SUBSTRINGS)


def _apply_urgent_gate(result: dict, detection: dict) -> dict:
    """Downgrades "urgent" to "high" unless BOTH the distance and the
    hazard/object type independently back it up. Neither the model's
    distance judgment nor its type judgment is trusted alone -- this
    requires the detection's own sensor-reported distance_m (not the
    model's guess from the frame) AND a type match against a short
    allow-list of genuinely life-threatening categories. "Urgent" is the
    only tier ContentView.swift will treat as SOS-eligible, so this gate is
    deliberately strict and only ever downgrades, never upgrades.
    """
    if result.get("urgency") != "urgent":
        return result

    distance_m = detection.get("distance_m")
    try:
        distance_val = float(distance_m)
    except (TypeError, ValueError):
        distance_val = None

    distance_ok = distance_val is not None and distance_val <= _URGENT_MAX_DISTANCE_M
    type_ok = _mentions_urgent_type(
        result.get("hazard_type", ""), detection.get("object_class", "")
    )

    if distance_ok and type_ok:
        return result

    logger.info(
        "Downgrading urgent->high: distance_ok=%s type_ok=%s "
        "(distance_m=%r, hazard_type=%r, object_class=%r)",
        distance_ok, type_ok, distance_m,
        result.get("hazard_type"), detection.get("object_class"),
    )
    result = dict(result)
    result["urgency"] = "high"
    return result


# Distance beyond which we don't trust a "high" label regardless of what the
# model returned -- a model can still misjudge proximity from a single 2D
# frame, so this acts as a hard backstop rather than relying purely on
# prompt-following. Tune based on real sensor accuracy; this is deliberately
# conservative (errs toward downgrading, never upgrading).
_HIGH_URGENCY_MAX_DISTANCE_M = 1.5


def _apply_distance_gate(result: dict, detection: dict) -> dict:
    """Downgrades a "high" label to "medium" if the triggering detection's
    own distance reading contradicts it. Never upgrades urgency -- if
    distance is missing/unparsable we leave the model's judgment alone
    rather than guessing.
    """
    if result.get("urgency") != "high":
        return result
    distance_m = detection.get("distance_m")
    try:
        distance_val = float(distance_m)
    except (TypeError, ValueError):
        return result
    if distance_val > _HIGH_URGENCY_MAX_DISTANCE_M:
        logger.info(
            "Downgrading high->medium urgency: distance_m=%.2f exceeds gate of %.2f",
            distance_val, _HIGH_URGENCY_MAX_DISTANCE_M,
        )
        result = dict(result)
        result["urgency"] = "medium"
    return result


def _parse_response_text(text: str) -> dict:
    # Defensive: even though the prompt asks for no markdown fences, models
    # sometimes wrap JSON in ```json ... ``` anyway. Strip that off before
    # parsing.
    cleaned = _MARKDOWN_FENCE_RE.sub("", text).strip()
    parsed = json.loads(cleaned)

    # Only pull out the four contract fields -- anything else the model
    # adds gets dropped rather than leaking into the WebSocket payload.
    return {
        "hazard_type": str(parsed["hazard_type"]),
        "direction": str(parsed["direction"]),
        "urgency": str(parsed["urgency"]),
        "spoken_description": str(parsed["spoken_description"]),
    }


async def _call_gemini(client: "genai.Client", image_bytes: bytes, detection: dict) -> dict:
    response = await client.aio.models.generate_content(
        model=MODEL_NAME,
        contents=[
            _build_prompt(detection),
            types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg"),
        ],
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
        ),
    )
    return _parse_response_text(response.text)


async def analyze_hazard(image_bytes: bytes, detection: dict) -> dict:
    """
    Stage 3 entry point. Sends the frame + detection context to Gemini and
    returns a dict matching the fixed hazard contract:
    {hazard_type, direction, urgency, spoken_description}.

    Never raises -- on any failure (network, bad JSON, missing API key,
    etc.) this logs the error and returns a safe low-urgency fallback so a
    single bad Gemini call can't take down the rest of the pipeline (a
    missed narration is far better than a crashed server for a user relying
    on this for safety).

    Makes one retry attempt on the first failure before falling back, since
    a lot of failures at this layer are transient (rate limits, brief
    network hiccups).
    """
    last_error: Exception | None = None
    for attempt in range(2):  # initial attempt + 1 retry
        try:
            # _get_client() (e.g. a missing GEMINI_API_KEY) can raise just
            # as easily as the network call itself -- it must stay inside
            # this try, not run before it, or a bad key crashes the
            # pipeline's background task instead of hitting the fallback.
            client = _get_client()
            result = await _call_gemini(client, image_bytes, detection)
            result = _apply_urgent_gate(result, detection)
            return _apply_distance_gate(result, detection)
        except Exception as exc:  # noqa: BLE001 - deliberately broad, see docstring
            last_error = exc
            logger.warning(
                "Gemini hazard analysis failed (attempt %d/2): %s", attempt + 1, exc
            )

    logger.error("Gemini hazard analysis failed after retry, using fallback: %s", last_error)
    return dict(_FALLBACK_RESULT)