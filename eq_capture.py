#!/usr/bin/env python3
# eq_capture.py — WASAPI loopback FFT -> WebSocket
# pip install pyaudiowpatch numpy websocket-client

import pyaudiowpatch as pyaudio
import numpy as np
import websocket, json, threading, time, os

WS_URL     = "ws://localhost:8765/?client=eq"
CHUNK      = 2048
SMOOTH     = 0.75
# Per-band scale
SCALE = {
    'b60':   400.0,
    'b150':  120.0,
    'b400':  300.0,
    'k1':    600.0,
    'k2_4':  1200.0,
    'k15':   4000.0,
}

CONFIG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "eq_config.json")

# ── WebSocket ─────────────────────────────────────────────────────────────────
ws_app    = None
connected = False
ws_lock   = threading.Lock()

def send_bands(bands):
    with ws_lock:
        if not connected or not ws_app: return
        try:
            msg = {"type": "eq"}
            msg.update({k: round(v, 4) for k, v in bands.items()})
            ws_app.send(json.dumps(msg))
        except: pass

def on_open(ws):
    global connected; connected = True
    print("[eq] Connected to server")
def on_close(ws, *a):
    global connected; connected = False
    print("[eq] Disconnected, reconnecting...")
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
            print(f"[eq] WS error: {e}")
        time.sleep(3)

# ── FFT ───────────────────────────────────────────────────────────────────────
def get_bands(pcm, rate, channels):
    mono = pcm.reshape(-1, channels).mean(axis=1) if channels > 1 else pcm
    if len(mono) < 64: return 0.0, 0.0, 0.0
    window = np.hanning(len(mono))
    fft    = np.abs(np.fft.rfft(mono * window)) / (len(mono) / 2)
    freqs  = np.fft.rfftfreq(len(mono), d=1.0 / rate)
    def rms(lo, hi, scale):
        idx = np.where((freqs >= lo) & (freqs < hi))[0]
        if not len(idx): return 0.0
        return float(np.clip(np.sqrt(np.mean(fft[idx]**2)) * scale, 0, 1))
    return {
        'b60':  rms(40,    100,  SCALE['b60']),   # kick, bass
        'b150': rms(100,   300,  SCALE['b150']),  # bass body
        'b400': rms(300,   800,  SCALE['b400']),  # low mids
        'k1':   rms(800,   2500, SCALE['k1']),    # mids
        'k2_4': rms(2500,  6000, SCALE['k2_4']),  # presence
        'k15':  rms(6000,  20000,SCALE['k15']),   # air/treble
    }

# ── Найти устройство захвата ──────────────────────────────────────────────────
def load_config():
    """Загрузить сохранённое устройство из eq_config.json."""
    try:
        with open(CONFIG_FILE, encoding="utf-8") as f:
            return json.load(f)
    except:
        return {}

def find_loopback(pa):
    """Найти loopback устройство — сначала из конфига, потом CABLE Input, потом дефолт."""
    config      = load_config()
    saved_name  = config.get("device_name", "")

    devices = []
    for i in range(pa.get_device_count()):
        d = pa.get_device_info_by_index(i)
        if d.get("isLoopbackDevice"):
            d["index"] = i
            devices.append(d)

    if not devices:
        return None

    # 1. Сохранённое устройство
    if saved_name:
        for d in devices:
            if saved_name in d["name"]:
                print(f"[eq] Устройство из конфига: {d['name']}")
                return d

    # 2. CABLE Input (VB-Audio)
    for d in devices:
        if "CABLE Input" in d["name"]:
            print(f"[eq] Автовыбор CABLE Input: {d['name']}")
            return d

    # 3. Дефолтное выходное устройство
    try:
        wasapi  = pa.get_host_api_info_by_type(pyaudio.paWASAPI)
        default = pa.get_device_info_by_index(wasapi["defaultOutputDevice"])
        for d in devices:
            if default["name"] in d["name"]:
                print(f"[eq] Автовыбор дефолтного: {d['name']}")
                return d
    except: pass

    # 4. Первое доступное
    print(f"[eq] Fallback на первое loopback: {devices[0]['name']}")
    return devices[0]

# ── Audio loop ────────────────────────────────────────────────────────────────
def audio_loop():
    pa      = pyaudio.PyAudio()
    smooth  = {k: 0.0 for k in SCALE}
    stream  = None
    current = None

    while True:
        loopback = find_loopback(pa)
        if not loopback:
            print("[eq] Loopback устройства не найдены. Установлен ли VB-Audio Virtual Cable?")
            time.sleep(5); continue

        if current != loopback["index"]:
            if stream:
                stream.stop_stream(); stream.close()
            current  = loopback["index"]
            rate     = int(loopback["defaultSampleRate"])
            channels = loopback["maxInputChannels"]
            print(f"[eq] Захват: {loopback['name']} @ {rate} Hz, {channels} ch")
            stream = pa.open(
                format=pyaudio.paFloat32,
                channels=channels,
                rate=rate,
                input=True,
                input_device_index=current,
                frames_per_buffer=CHUNK,
            )

        try:
            data  = stream.read(CHUNK, exception_on_overflow=False)
            audio = np.frombuffer(data, dtype=np.float32)
            bands = get_bands(audio, rate, channels)
            for k in bands:
                smooth[k] = SMOOTH * smooth.get(k, 0) + (1 - SMOOTH) * bands[k]
            send_bands(smooth)
        except Exception as e:
            print(f"[eq] Stream error: {e}")
            time.sleep(1); current = None

if __name__ == "__main__":
    print("[eq] Starting... (Ctrl+C to stop)")
    threading.Thread(target=ws_thread, daemon=True).start()
    time.sleep(1)
    try:
        audio_loop()
    except KeyboardInterrupt:
        print("\n[eq] Stopped")
