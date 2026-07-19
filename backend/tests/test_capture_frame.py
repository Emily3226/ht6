"""
Tests for detection_input.capture_frame() (real camera board, added
2026-07-19): successful response returns bytes; timeout, connection
error, non-200 response, empty body, and corrupt/undecodable image bytes
all return None without raising.

Uses asyncio.run() directly (matching the convention already used
elsewhere in this suite) rather than adding a pytest-asyncio dependency.
"""

import asyncio
import io
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from PIL import Image

from pipeline import detection_input


def _real_jpeg_bytes() -> bytes:
    image = Image.new("RGB", (8, 8), color=(1, 2, 3))
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG")
    return buffer.getvalue()


def _fake_response(status_code: int, content: bytes):
    return SimpleNamespace(status_code=status_code, content=content)


def test_capture_frame_sync_returns_bytes_on_success(monkeypatch):
    jpeg_bytes = _real_jpeg_bytes()

    def fake_get(url, timeout):
        return _fake_response(200, jpeg_bytes)

    monkeypatch.setattr(detection_input._frame_session, "get", fake_get)

    result = detection_input._capture_frame_sync()
    assert result == jpeg_bytes


def test_capture_frame_sync_returns_none_on_connection_error(monkeypatch):
    def fake_get(url, timeout):
        raise ConnectionError("board unreachable")

    monkeypatch.setattr(detection_input._frame_session, "get", fake_get)

    assert detection_input._capture_frame_sync() is None


def test_capture_frame_sync_returns_none_on_timeout(monkeypatch):
    def fake_get(url, timeout):
        raise TimeoutError("timed out")

    monkeypatch.setattr(detection_input._frame_session, "get", fake_get)

    assert detection_input._capture_frame_sync() is None


def test_capture_frame_sync_returns_none_on_non_200(monkeypatch):
    def fake_get(url, timeout):
        return _fake_response(500, _real_jpeg_bytes())

    monkeypatch.setattr(detection_input._frame_session, "get", fake_get)

    assert detection_input._capture_frame_sync() is None


def test_capture_frame_sync_returns_none_on_empty_body(monkeypatch):
    def fake_get(url, timeout):
        return _fake_response(200, b"")

    monkeypatch.setattr(detection_input._frame_session, "get", fake_get)

    assert detection_input._capture_frame_sync() is None


def test_capture_frame_sync_returns_none_on_corrupt_image_bytes(monkeypatch):
    def fake_get(url, timeout):
        return _fake_response(200, b"this is not a real image, just garbage bytes")

    monkeypatch.setattr(detection_input._frame_session, "get", fake_get)

    assert detection_input._capture_frame_sync() is None


def test_capture_frame_async_wrapper_delegates_to_sync_off_thread(monkeypatch):
    monkeypatch.setattr(detection_input, "_capture_frame_sync", lambda: b"fake-jpeg-bytes")
    result = asyncio.run(detection_input.capture_frame())
    assert result == b"fake-jpeg-bytes"


def test_capture_frame_async_wrapper_propagates_none(monkeypatch):
    monkeypatch.setattr(detection_input, "_capture_frame_sync", lambda: None)
    result = asyncio.run(detection_input.capture_frame())
    assert result is None


def test_mock_capture_frame_still_usable_and_returns_bytes():
    result = detection_input.mock_capture_frame()
    assert isinstance(result, bytes)
    assert len(result) > 0
