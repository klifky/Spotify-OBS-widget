#!/usr/bin/env python3
# smtc_reader.py — reads Spotify track info via Windows Media Session API
# and sends to widget server via WebSocket
# pip install winrt-Windows.Media.Control winrt-Windows.Storage.Streams
#             winrt-Windows.Foundation winrt-Windows.Foundation.Collections
#             websocket-client

import asyncio
import base64
import json
import threading
import time
import websocket

from winrt.windows.media.control import (
    GlobalSystemMediaTransportControlsSessionManager as GSMTCS,
    GlobalSystemMediaTransportControlsSessionPlaybackStatus as PlaybackStatus,
)
from winrt.windows.storage.streams import DataReader, Buffer, InputStreamOptions

WS_URL   = "ws://localhost:8765/?client=smtc"
POLL_MS  = 1000

# ── WebSocket ─────────────────────────────────────────────────────────────────
ws_app    = None
connected = False
ws_lock   = threading.Lock()

def send_state(payload):
    with ws_lock:
        if not connected or not ws_app: return
        try:
            ws_app.send(json.dumps(payload))
        except: pass

def on_open(ws):
    global connected; connected = True
    print("[smtc] Connected to server")

def on_close(ws, *a):
    global connected; connected = False
    print("[smtc] Disconnected, reconnecting...")

def on_error(ws, e):
    global connected; connected = False

def ws_thread():
    global ws_app
    while True:
        try:
            ws_app = websocket.WebSocketApp(WS_URL,
                on_open=on_open, on_close=on_close, on_error=on_error)
            ws_app.run_forever()
        except Exception as e:
            print(f"[smtc] WS error: {e}")
        time.sleep(3)

# ── Thumbnail reader ──────────────────────────────────────────────────────────
async def read_thumbnail(thumb_ref):
    try:
        stream = await thumb_ref.open_read_async()
        size   = stream.size
        if size == 0: return None
        buf    = Buffer(size)
        await stream.read_async(buf, size, InputStreamOptions.READ_AHEAD)
        reader = DataReader.from_buffer(buf)
        data   = bytearray(size)
        for i in range(size):
            data[i] = reader.read_byte()
        mime = "image/png" if data[:4] == b'\x89PNG' else "image/jpeg"
        b64  = base64.b64encode(bytes(data)).decode()
        return f"data:{mime};base64,{b64}"
    except Exception as e:
        print(f"[smtc] Thumbnail error: {e}")
        return None

# ── Track ID (hash from title+artist to detect track changes) ─────────────────
def make_track_id(title, artist, album):
    import hashlib
    return hashlib.md5(f"{title}|{artist}|{album}".encode()).hexdigest()[:16]

# ── SMTC polling loop ─────────────────────────────────────────────────────────
last_track_id  = None
last_thumb_id  = None
last_thumb_b64 = None
last_position  = 0.0   # for drift filtering
last_poll_time = 0.0   # real time of last poll

async def poll_once():
    global last_track_id, last_thumb_id, last_thumb_b64, last_position, last_poll_time

    try:
        mgr      = await GSMTCS.request_async()
        sessions = mgr.get_sessions()
    except Exception as e:
        print(f"[smtc] Session error: {e}")
        return

    # Find Spotify session
    spotify = None
    for s in sessions:
        if "Spotify" in s.source_app_user_model_id:
            spotify = s; break

    if not spotify:
        return

    try:
        info     = await spotify.try_get_media_properties_async()
        timeline = spotify.get_timeline_properties()
        pb       = spotify.get_playback_info()
    except Exception as e:
        print(f"[smtc] Properties error: {e}")
        return

    title  = info.title  or ""
    artist = info.artist or ""
    album  = info.album_title or ""

    if not title: return

    duration_s = timeline.end_time.total_seconds()
    raw_pos    = timeline.position.total_seconds()
    playing    = (pb.playback_status == PlaybackStatus.PLAYING)

    # Filter SMTC position jitter — if playing, extrapolate from last known position
    now = time.monotonic()
    elapsed = now - last_poll_time if last_poll_time > 0 else 0
    expected = last_position + elapsed if playing else last_position
    # Accept SMTC value if it differs from expected by more than 1.5s (real seek)
    # otherwise use it directly (SMTC is authoritative)
    position_s = raw_pos
    last_position = raw_pos
    last_poll_time = now

    progress   = (position_s / duration_s) if duration_s > 0 else 0

    track_id = make_track_id(title, artist, album)

    # Get thumbnail — only re-read when track changes
    art_url = None
    if track_id != last_thumb_id:
        if info.thumbnail:
            b64 = await read_thumbnail(info.thumbnail)
            if b64:
                last_thumb_b64 = b64
                last_thumb_id  = track_id
        else:
            last_thumb_b64 = None
            last_thumb_id  = track_id

    art_url = last_thumb_b64

    is_new_track = (track_id != last_track_id)

    if is_new_track:
        # Full payload with art — only on track change
        payload = {
            "trackId":  track_id,
            "name":     title,
            "artist":   artist,
            "album":    album,
            "artUrl":   art_url or "",
            "playlist": "",
            "duration": int(duration_s * 1000),
            "position": int(position_s * 1000),
            "playing":  playing,
            "progress": round(progress, 6),
            "analysis": None,
        }
        last_track_id = track_id
        print(f"[smtc] Now playing: {title} — {artist}")
    else:
        # Lightweight update — no art, no name, just playback state
        payload = {
            "trackId":  track_id,
            "name":     title,
            "artist":   artist,
            "album":    album,
            "artUrl":   None,        # skip — widget keeps current art
            "playlist": "",
            "duration": int(duration_s * 1000),
            "position": int(position_s * 1000),
            "playing":  playing,
            "progress": round(progress, 6),
            "analysis": None,
        }

    send_state(payload)

async def poll_loop():
    while True:
        await poll_once()
        await asyncio.sleep(POLL_MS / 1000)

# ── Main ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("[smtc] Starting Spotify SMTC reader...")
    print("[smtc] Connecting to ws://localhost:8765")
    threading.Thread(target=ws_thread, daemon=True).start()
    time.sleep(1)
    try:
        asyncio.run(poll_loop())
    except KeyboardInterrupt:
        print("\n[smtc] Stopped")
