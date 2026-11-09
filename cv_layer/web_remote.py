"""
web_remote.py  —  Flask phone remote for LightTable.

Runs in a background daemon thread started by main.py.
Open  http://<machine-ip>:5000  on any phone on the same WiFi/LAN.

Configure the PIN in remote_config.json at the project root. If no valid PIN
is configured, a temporary PIN is generated. Sessions use a per-run secret.

Commands are sent directly over UDP to Godot on port 7000 using the same
JSON-over-UDP protocol as the CV layer.

Tracker changes are handled via ControlState which the CV main loop polls
each frame.
"""

import json
import math
import secrets
import socket
import threading
import time
from collections import deque
from datetime import timedelta
from pathlib import Path
from urllib.parse import urlsplit

from flask import Flask, jsonify, redirect, request, session, url_for
from operator_preview import OperatorPreview
from environment_presets import EnvironmentPresets

# ─────────────────────────────────────────────────────────────────────────────
# Config  (remote_config.json at project root, one level above cv_layer/)
# ─────────────────────────────────────────────────────────────────────────────
_CFG_PATH = Path(__file__).parent.parent / "remote_config.json"
_DEFAULTS  = {"port": 5000}


def _validate_operator_values(values, specs):
    if not isinstance(values, dict):
        raise ValueError("settings must be an object")
    for name, value in values.items():
        spec = specs.get(name)
        if spec is None:
            raise ValueError(f"unknown setting: {name}")
        if "options" in spec:
            valid = isinstance(value, str) and value in spec["options"]
        elif spec.get("type") == "boolean":
            valid = isinstance(value, bool)
        else:
            valid = type(value) is int and spec["min"] <= value <= spec["max"]
        if not valid:
            raise ValueError(f"invalid value for {name}")


def _load_config() -> dict:
    cfg = dict(_DEFAULTS)
    if _CFG_PATH.exists():
        try:
            with open(_CFG_PATH) as f:
                saved = json.load(f)
            if isinstance(saved, dict):
                cfg.update(saved)
        except (OSError, ValueError, TypeError) as exc:
            print(f"[WebRemote] Invalid remote configuration; using defaults: {exc}")
    pin = str(cfg.get("pin", ""))
    if not pin.isascii() or not pin.isdigit() or not 4 <= len(pin) <= 12:
        cfg["pin"] = f"{secrets.randbelow(1_000_000):06d}"
        cfg["generated_pin"] = True
    else:
        cfg["generated_pin"] = False
        if len(pin) < 6:
            print("[WebRemote] Warning: short PINs are easy to guess; use a private six-digit or longer PIN on shared networks.")
    try:
        cfg["port"] = max(1024, min(65535, int(cfg.get("port", 5000))))
    except (TypeError, ValueError):
        cfg["port"] = 5000
    # Do not trust or reuse a repository-stored signing key for LAN sessions.
    cfg["secret_key"] = secrets.token_hex(32)
    return cfg


def _get_local_ip() -> str:
    """Best-effort: return the LAN IP that can reach external hosts."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"


# ─────────────────────────────────────────────────────────────────────────────
# Scene registry  (must match main.gd)
# ─────────────────────────────────────────────────────────────────────────────
SCENES = [
    "Water", "Balloons", "Bouncing Balls", "Elements", "Galaxy",
    "Draw", "Talk Back", "Spinner", "Blob Painter", "Color Trails",
    "Edge Reveal", "Piano", "Alphabet", "Bug",
]
SCENE_SCRIPTS = {
    "Water":          "res://scripts/content/water_scene.gd",
    "Balloons":       "res://scripts/content/balloons_scene.gd",
    "Bouncing Balls": "res://scripts/content/bouncing_balls_scene.gd",
    "Elements":       "res://scripts/content/elements_scene.gd",
    "Galaxy":         "res://scripts/content/galaxy_scene.gd",
    "Draw":           "res://scripts/content/freehand_draw_scene.gd",
    "Talk Back":      "res://scripts/content/talk_back_scene.gd",
    "Spinner":        "res://scripts/content/spinner_scene.gd",
    "Blob Painter":   "res://scripts/content/blob_painter_scene.gd",
    "Color Trails":   "res://scripts/content/color_trails_scene.gd",
    "Edge Reveal":    "res://scripts/content/edge_reveal_scene.gd",
    "Piano":          "res://scripts/content/piano_scene.gd",
    "Alphabet":       "res://scripts/content/alphabet_puzzle.gd",
    "Bug":            "res://scripts/content/bug_scene.gd",
}
TRACKER_NAMES = ["Hands", "Blob", "Motion", "Color", "Edge", "Object"]
_PROFILES_PATH = Path(__file__).parent.parent / "profiles.json"


def _load_profiles() -> dict:
    if _PROFILES_PATH.exists():
        try:
            with open(_PROFILES_PATH) as f:
                data = json.load(f)
            if isinstance(data, dict) and isinstance(data.get("profiles"), list):
                valid_profiles = []
                for profile in data["profiles"]:
                    if (
                        isinstance(profile, dict)
                        and isinstance(profile.get("id"), str)
                        and isinstance(profile.get("first_name"), str)
                        and isinstance(profile.get("last_name"), str)
                        and isinstance(profile.get("created_at"), (int, float))
                        and math.isfinite(float(profile.get("created_at")))
                    ):
                        valid_profiles.append(profile)
                    else:
                        print("[WebRemote] Ignoring malformed player profile")
                return {"profiles": valid_profiles}
            print("[WebRemote] Invalid profiles format; using an empty profile list")
        except (OSError, ValueError, TypeError) as exc:
            print(f"[WebRemote] Profiles could not be loaded: {exc}")
    return {"profiles": []}


def _save_profiles(data: dict):
    try:
        with open(_PROFILES_PATH, "w") as f:
            json.dump(data, f, indent=2)
        return True
    except OSError as exc:
        print(f"[WebRemote] Profiles could not be saved: {exc}")
        return False


# ─────────────────────────────────────────────────────────────────────────────
# Thread-safe shared state
# ─────────────────────────────────────────────────────────────────────────────
class ControlState:
    """
    Shared between the Flask thread and the CV main loop.
      • Flask writes pending tracker changes; main loop pops + applies.
      • Main loop writes live status each frame; Flask reads for /status.
      • Flask writes current scene name (optimistic); main loop ignores.
    """

    def __init__(self):
        self._lock            = threading.Lock()
        self.preview = OperatorPreview()
        self._operator = None
        self._operator_commands = deque(maxlen=32)
        self._pending_tracker: int | None = None
        self._t0              = time.monotonic()
        self._godot_last_seen = 0.0
        self._audio_last_seen = 0.0
        self._pending_scene_time = 0.0
        self._status = {
            "scene":       "Not confirmed",
            "pending_scene": None,
            "pending_scene_id": None,
            "godot_connected": False,
            "audio_level": 0.0,
            "tracker":     TRACKER_NAMES[0],
            "tracker_idx": 0,
            "uptime_s":    0,
            "detections":  0,
            "player_id":   None,
            "player_name": "Guest",
            "camera": "unknown",
            "calibration": "unknown",
        }

    # ── Called by Flask thread ───────────────────────────────────────────────
    def request_tracker(self, idx: int):
        with self._lock:
            self._pending_tracker = idx

    def publish_operator(self, snapshot):
        with self._lock:
            self._operator = snapshot

    def operator_snapshot(self):
        with self._lock:
            return self._operator

    def queue_operator(self, command):
        with self._lock:
            if len(self._operator_commands) >= self._operator_commands.maxlen:
                return False
            self._operator_commands.append(command)
            return True

    def pop_operator_commands(self):
        with self._lock:
            commands = list(self._operator_commands)
            self._operator_commands.clear()
            return commands

    def set_scene_name(self, name: str, request_id=None):
        with self._lock:
            self._status["pending_scene"] = name
            self._status["pending_scene_id"] = request_id
            self._status["scene_error"] = None
            self._pending_scene_time = time.monotonic()

    def fail_scene_request(self, request_id):
        with self._lock:
            if self._status["pending_scene_id"] == request_id:
                self._status["pending_scene"] = None
                self._status["pending_scene_id"] = None
                self._status["scene_error"] = "Could not send scene request"

    def update_godot_status(self, data):
        with self._lock:
            if "scene" in data and isinstance(data["scene"], str):
                self._status["scene"] = data["scene"]
            for key in ("audio_raw", "audio_level", "audio_floor", "audio_ceil"):
                value = data.get(key)
                if type(value) in (float, int) and 0 <= value <= 1:
                    self._status[key] = value
            if data.get("audio_status") in ("active", "unavailable", "no input frames"):
                self._status["audio_status"] = data["audio_status"]
                self._audio_last_seen = time.monotonic()
            if data.get("request_id") == self._status["pending_scene_id"]:
                self._status["pending_scene"] = None
                self._status["pending_scene_id"] = None
                self._status["scene_error"] = None
            self._status["godot_connected"] = True
            self._godot_last_seen = time.monotonic()

    def set_player(self, player_id: str | None, player_name: str = "Guest"):
        with self._lock:
            self._status["player_id"] = player_id
            self._status["player_name"] = player_name

    # ── Called by CV main loop ───────────────────────────────────────────────
    def pop_tracker_request(self) -> int | None:
        """Returns pending tracker index and clears it, or None."""
        with self._lock:
            idx = self._pending_tracker
            self._pending_tracker = None
            return idx

    def update_status(self, audio: float, tracker_idx: int, detections: int, **diagnostics):
        with self._lock:
            self._status.update({
                "tracker":     TRACKER_NAMES[tracker_idx] if 0 <= tracker_idx < len(TRACKER_NAMES) else "?",
                "tracker_idx": tracker_idx,
                "uptime_s":    int(time.monotonic() - self._t0),
                "detections":  detections,
            })
            self._status.update(diagnostics)

    def get_status(self) -> dict:
        with self._lock:
            status = dict(self._status)
            now = time.monotonic()
            status["godot_connected"] = now - self._godot_last_seen < 10.0
            status["audio_fresh"] = now - self._audio_last_seen < 1.0
            if status["pending_scene"] and now - self._pending_scene_time > 10.0:
                status["pending_scene"] = None
                status["pending_scene_id"] = None
                status["scene_error"] = "No Godot confirmation received"
                self._status["pending_scene"] = None
                self._status["pending_scene_id"] = None
                self._status["scene_error"] = status["scene_error"]
            return status


# ─────────────────────────────────────────────────────────────────────────────
# HTML  — login page
# ─────────────────────────────────────────────────────────────────────────────
_LOGIN_HTML = r"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<title>Light Table</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
body{background:#06080d;color:#b0c8d0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
     min-height:100dvh;display:flex;flex-direction:column;align-items:center;
     justify-content:center;user-select:none;padding:1.2rem}
h1{font-size:1.9rem;font-weight:200;letter-spacing:.55em;color:#32cee8;margin-bottom:.22em;text-align:center;text-transform:uppercase}
.sub{font-size:.65rem;color:#264858;letter-spacing:.4em;text-transform:uppercase;margin-bottom:2.8rem;text-align:center}
.card{background:#0b1520;border:1px solid #16303e;border-radius:20px;padding:1.6rem 1.4rem 1.2rem;
      width:min(290px,92vw);box-shadow:0 0 60px rgba(0,150,190,.06)}
.dots{display:flex;justify-content:center;gap:1.1rem;margin-bottom:1.7rem;height:18px;align-items:center}
.dot{width:13px;height:13px;border-radius:50%;background:#0f1e28;border:1.5px solid #1c3848;transition:all .15s}
.dot.on{background:#32cee8;border-color:#32cee8;box-shadow:0 0 10px rgba(50,206,232,.45)}
.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:9px}
.k{background:#0d1c26;border:none;border-radius:13px;color:#b8d0d8;font-size:1.38rem;font-weight:300;
   padding:.88rem;cursor:pointer;text-align:center;touch-action:manipulation;-webkit-touch-callout:none;
   transition:background .1s,transform .08s}
.k:active{background:#1c3848;transform:scale(.92)}
.k.bk{font-size:1rem;color:#345868}
.k.ok{background:#0b2c3a;color:#32cee8;border:1px solid rgba(50,206,232,.35);font-size:1.05rem}
.k.ok:active{background:#174858}
.err{color:#c85858;font-size:.82rem;text-align:center;margin-top:.95rem;min-height:1.2em}
.hint{color:#162830;font-size:.66rem;text-align:center;margin-top:.6rem}
</style></head>
<body>
<h1>Light&nbsp;Table</h1>
<p class="sub">Remote Control</p>
<div class="card">
  <div class="dots">
    <span class="dot" id="d0"></span><span class="dot" id="d1"></span>
    <span class="dot" id="d2"></span><span class="dot" id="d3"></span>
    <span class="dot" id="d4"></span><span class="dot" id="d5"></span>
  </div>
  <div class="grid">
    <button class="k" ontouchstart="" onclick="p('1')">1</button>
    <button class="k" ontouchstart="" onclick="p('2')">2</button>
    <button class="k" ontouchstart="" onclick="p('3')">3</button>
    <button class="k" ontouchstart="" onclick="p('4')">4</button>
    <button class="k" ontouchstart="" onclick="p('5')">5</button>
    <button class="k" ontouchstart="" onclick="p('6')">6</button>
    <button class="k" ontouchstart="" onclick="p('7')">7</button>
    <button class="k" ontouchstart="" onclick="p('8')">8</button>
    <button class="k" ontouchstart="" onclick="p('9')">9</button>
    <button class="k bk" ontouchstart="" onclick="bk()">&#9003;</button>
    <button class="k" ontouchstart="" onclick="p('0')">0</button>
    <button class="k ok" ontouchstart="" onclick="go()">&#10003;</button>
  </div>
  <div class="err" id="err"></div>
  <div class="hint">Change PIN in remote_config.json</div>
</div>
<script>
let pin='';
function upd(){for(let i=0;i<6;i++)document.getElementById('d'+i).className='dot'+(i<pin.length?' on':'')}
function p(d){if(pin.length<12){pin+=d;upd()}}
function bk(){if(pin.length){pin=pin.slice(0,-1);upd()}}
async function go(){
  if(!pin.length)return;
  const r=await fetch('/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({pin})});
  const d=await r.json();
  if(d.ok){location.href='/'}
  else{document.getElementById('err').textContent='Incorrect PIN';pin='';upd();
       setTimeout(()=>{document.getElementById('err').textContent=''},2200)}}
document.addEventListener('keydown',e=>{
  if(e.key>='0'&&e.key<='9')p(e.key);
  else if(e.key==='Backspace')bk();
  else if(e.key==='Enter')go();
});
</script>
</body></html>"""

# ─────────────────────────────────────────────────────────────────────────────
# HTML  — main control page  (%%SCENE_BUTTONS%% and %%TRACKER_OPTIONS%% replaced at build time)
# ─────────────────────────────────────────────────────────────────────────────
_MAIN_HTML = r"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<title>Light Table Remote</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
body{background:#06080d;color:#a8c0c8;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
     min-height:100dvh;padding-bottom:5rem;user-select:none}
header{background:#0b1520;border-bottom:1px solid #142834;padding:.75rem 1rem;
       display:flex;align-items:center;justify-content:space-between;
       position:sticky;top:0;z-index:20;gap:.5rem}
.logo{font-size:1rem;font-weight:200;letter-spacing:.4em;color:#32cee8;text-transform:uppercase;white-space:nowrap}
.hdr-r{display:flex;align-items:center;gap:.55rem;flex-shrink:0}
.conn{width:8px;height:8px;border-radius:50%;background:#8a2828;flex-shrink:0;transition:background .6s}
.conn.live{background:#28a868}
.logout{background:none;border:1px solid #1c3848;border-radius:9px;color:#3a6070;
        font-size:.72rem;padding:.32rem .65rem;cursor:pointer;letter-spacing:.05em;white-space:nowrap}
.logout:active{background:#1c3848}

/* Profile styles */
.prof-bar{background:#0b1520;border-bottom:1px solid #142834;padding:.5rem .75rem;display:flex;align-items:center;justify-content:space-between;gap:.5rem}
.prof-info{font-size:.85rem;color:#32cee8;font-weight:300}
.prof-btn{background:#0d1c26;border:1px solid #1c3848;border-radius:6px;color:#32cee8;font-size:.65rem;padding:.25rem .5rem}

.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.85);z-index:100;align-items:center;justify-content:center}
.modal-content{background:#0b1520;border:1px solid #1c3848;border-radius:15px;width:min(320px,90vw);padding:1.5rem}
.modal-h{font-size:.9rem;color:#32cee8;margin-bottom:1rem;text-transform:uppercase;letter-spacing:.1em}
.prof-list{max-height:200px;overflow-y:auto;margin-bottom:1rem;border:1px solid #1c3848;border-radius:8px}
.prof-item{padding:.75rem;border-bottom:1px solid #0d1c26;cursor:pointer;font-size:.85rem}
.prof-item:last-child{border-bottom:none}
.prof-item:active{background:#112233}
.prof-form{display:flex;flex-direction:column;gap:.5rem}
.prof-input{background:#0d1c26;border:1px solid #1c3848;border-radius:6px;color:#fff;padding:.5rem;font-size:.85rem}
.prof-submit{background:#153040;border:1px solid #32cee8;color:#32cee8;border-radius:6px;padding:.5rem;margin-top:.5rem}
.prof-close{background:none;border:none;color:#666;font-size:1.2rem;position:absolute;top:10px;right:10px}

.status-card{background:#0b1520;border:1px solid #14283a;border-radius:14px;
             margin:.75rem;padding:.9rem 1rem}
.scene-now{font-size:1.3rem;font-weight:200;color:#32cee8;letter-spacing:.08em;margin-bottom:.55rem;
           white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.status-extra{font-size:.68rem;color:#547482;line-height:1.6;margin-top:.4rem}
.stat-row{display:flex;align-items:center;gap:.75rem;font-size:.72rem;color:#345868}
.abar{flex:1;height:5px;background:#101c28;border-radius:3px;overflow:hidden}
.afill{height:100%;background:linear-gradient(90deg,#28a868,#32cee8);width:0%;
       transition:width .35s;border-radius:3px}
.sec{font-size:.62rem;font-weight:700;letter-spacing:.25em;color:#32cee8;text-transform:uppercase;
     margin:.85rem .75rem .4rem;opacity:.65}
.scene-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;margin:0 .75rem}
.sb{background:#0d1c26;border:1px solid #152c38;border-radius:13px;color:#7098a8;
    font-size:.88rem;padding:.85rem .4rem;cursor:pointer;text-align:center;
    touch-action:manipulation;transition:background .1s,border-color .12s,color .12s;
    font-weight:300;letter-spacing:.04em}
.sb:active{transform:scale(.96)}
.sb.active{background:#0a2838;border-color:#32cee8;color:#32cee8;
           box-shadow:0 0 14px rgba(50,206,232,.12)}
.ctrl-card{background:#0b1520;border:1px solid #14283a;border-radius:14px;
           margin:.75rem;padding:.9rem 1rem}
.crow{display:flex;align-items:center;gap:.6rem;margin-bottom:.65rem}
.crow:last-child{margin-bottom:0}
.clbl{font-size:.72rem;color:#345868;width:64px;flex-shrink:0}
select{background:#0d1c26;border:1px solid #1c3848;border-radius:9px;color:#a8c0c8;
       font-size:.85rem;padding:.38rem .5rem;flex:1;outline:none;
       -webkit-appearance:none;appearance:none}
input[type=range]{flex:1;accent-color:#32cee8;height:22px;cursor:pointer}
.cval{font-size:.72rem;color:#32cee8;width:32px;text-align:right;flex-shrink:0}
.footer{position:fixed;bottom:0;left:0;right:0;background:#06080d;
        border-top:1px solid #101e28;padding:.65rem .75rem;
        display:flex;align-items:center;gap:.6rem}
.clr-btn{flex:1;background:#1a0d0d;border:1px solid #3a1818;border-radius:12px;
         color:#c05858;font-size:.85rem;padding:.72rem;cursor:pointer;
         touch-action:manipulation}
.clr-btn:active{background:#2a1414}
.uptime{font-size:.68rem;color:#1e3848;white-space:nowrap}
.tabs{display:flex;gap:.3rem;overflow:auto;padding:.6rem;position:sticky;top:3.3rem;background:#06080d;z-index:10}
.tabs button,.opbutton{background:#0d1c26;border:1px solid #1c3848;color:#a8c0c8;border-radius:8px;padding:.6rem;cursor:pointer}
.tabs button.active{border-color:#32cee8;color:#32cee8}
.settings-tabs{position:static;padding-top:0}
.settings-tabs[hidden]{display:none}
.settings-tabs button{white-space:nowrap}
.operator-page[hidden]{display:none}
.oprow{display:flex;align-items:center;gap:.6rem;margin:.5rem 0}
.oprow label{min-width:110px;font-size:.8rem}
.oprow output{min-width:3rem;text-align:right}
.op-hint{font-size:.8rem;line-height:1.5;color:#7897a4;margin:.5rem 0}
.preview{display:block;width:100%;height:auto;max-width:640px;background:#111;touch-action:manipulation}
.meter{width:100%;height:1rem}
.meter-wrap{position:relative}
.meter-marker{position:absolute;top:0;height:100%;width:2px;background:#ffcc55;pointer-events:none}
.op-error{color:#ffb075;min-height:1.2em}
</style></head>
<body>
<header>
  <span class="logo">Light&nbsp;Table</span>
  <div class="hdr-r">
    <span class="conn" id="conn"></span>
    <button class="logout" onclick="location.href='/logout'">Sign out</button>
  </div>
</header>

<div class="prof-bar">
  <div class="prof-info" id="profDisplay">Hi, <b>Guest</b>!</div>
  <div style="display:flex;gap:5px">
    <button class="prof-btn" onclick="location.href='/export'">Export</button>
    <button class="prof-btn" onclick="openProfiles()">Players</button>
  </div>
</div>

<nav class="tabs" aria-label="Main navigation">
  <button id="nav-play" class="active" onclick="showPage('play')">Play</button>
  <button id="nav-settings" onclick="showPage('settings')" aria-label="Settings">&#9881; Settings</button>
</nav>
<nav id="settingsNav" class="tabs settings-tabs" aria-label="Settings sections" hidden>
  <button data-page="tracking" onclick="showPage('tracking')">Tracking</button>
  <button data-page="calibration" onclick="showPage('calibration')">Calibration</button>
  <button data-page="diagnostics" onclick="showPage('diagnostics')">Diagnostics</button>
  <button data-page="settings" onclick="showPage('settings')">Preferences</button>
</nav>
<div id="operatorError" class="op-error" role="status"></div>
<section id="page-play" class="operator-page">
<div class="status-card">
  <div class="scene-now" id="sceneName">—</div>
  <div class="stat-row">
    <div class="abar"><div class="afill" id="afill"></div></div>
    <span id="detTxt">0 pts</span>
  </div>
  <div class="status-extra" id="runtimeStatus">Waiting for application status…</div>
</div>

<div class="sec">Scenes</div>
<div class="scene-grid">%%SCENE_BUTTONS%%</div>
</section>

<section id="page-tracking" class="operator-page" hidden>
<div class="sec">Tracking</div>
<div class="ctrl-card">
  <div class="oprow"><label for="trackerSelect">Tracking method</label>
    <select id="trackerSelect" onchange="chooseTracker(this.value)"></select></div>
  <div id="trackerStatus" class="op-hint">Waiting for tracker status</div>
  <div id="trackerControls"></div>
</div>
<div class="sec">Camera and processing</div>
<div class="ctrl-card">
  <div id="trackingControls"></div>
</div>
<div class="sec">Live preview</div>
<div class="ctrl-card">
  <label>Preview <select id="previewMode"><option value="camera">Adjusted camera</option><option value="overlay">Tracking overlay</option><option value="motion">Motion intensity</option></select></label>
  <label>Refresh <select id="previewRate"><option value="200">5 fps</option><option value="500">2 fps</option><option value="1000">1 fps</option></select></label>
  <img id="trackingPreview" class="preview" alt="Tracking camera preview">
  <div id="objectControls" hidden>
    <p>Object tracker: select the top-left and bottom-right corners on the adjusted camera preview.</p>
    <button class="opbutton" onclick="beginObjectSelection()">Select object</button>
    <button class="opbutton" onclick="postJson('/operator/object',{action:'clear'})">Clear objects</button>
  </div>
</div>
</section>

<section id="page-calibration" class="operator-page" hidden>
  <div class="ctrl-card">
    <div id="calStatus">Waiting for camera</div>
    <p>Start, then tap top-left, top-right, bottom-right, bottom-left.</p>
    <img id="calPreview" class="preview" alt="Calibration camera preview" onclick="calibrationPoint(event)">
    <label>Saved profile <select id="calProfiles"></select></label>
    <div id="calButtons"></div>
  </div>
</section>
<section id="page-diagnostics" class="operator-page" hidden>
<div class="ctrl-card">
  <div id="diagnosticsText"></div>
  <div id="diagnosticsDetail"></div>
</div>
<div class="sec">Microphone</div>
<div class="ctrl-card">
  <div id="micStatus">Waiting for Godot</div>
  <div>Incoming <span id="rawValue">—</span> (yellow markers: floor and ceiling)</div><div class="meter-wrap"><progress id="rawMeter" class="meter" max="1" value="0"></progress><span id="floorMarker" class="meter-marker"></span><span id="ceilMarker" class="meter-marker"></span></div>
  <div>Mapped <span id="mappedValue">—</span></div><progress id="mappedMeter" class="meter" max="1" value="0"></progress>
  <div class="crow">
    <span class="clbl">Floor</span>
    <input type="range" id="floorSlider" min="0" max="999" value="10" oninput="sliderMoved()">
    <span class="cval" id="floorVal">0.01</span>
  </div>
  <div class="crow">
    <span class="clbl">Ceiling</span>
    <input type="range" id="ceilSlider" min="1" max="1000" value="180" oninput="sliderMoved()">
    <span class="cval" id="ceilVal">0.18</span>
  </div>
</div>
</section>
<section id="page-settings" class="operator-page" hidden>
  <div class="ctrl-card">
    <div>Environment presets</div>
    <select id="presetList"></select>
    <div><button class="opbutton" onclick="presetAction('load')">Load</button>
    <button class="opbutton" onclick="presetAction('rename')">Rename</button>
    <button class="opbutton" onclick="presetAction('delete')">Delete</button>
    <button class="opbutton" onclick="presetAction('save')">Save current</button></div>
    <p>Presets save tracking, camera, image, motion, and confirmed audio settings. Calibration is loaded only for a matching camera configuration.</p>
    <p>Preview refresh settings are local to this browser session.</p>
    <p>These controls restart or stop the CV and web remote process, not Godot.</p>
    <button class="opbutton" onclick="lifecycle('restart')">Restart CV and remote</button>
    <button class="opbutton" onclick="lifecycle('shutdown')">Stop CV and remote</button>
  </div>
</section>

<div class="footer">
  <button class="clr-btn" onclick="clearCursors()">Clear Cursors</button>
  <div class="uptime" id="uptimeTxt">—</div>
</div>

<!-- Profiles Modal -->
<div id="profModal" class="modal">
  <div class="modal-content" style="position:relative">
    <button class="prof-close" onclick="closeProfiles()">&times;</button>
    <div class="modal-h">Player Profiles</div>
    <div id="profList" class="prof-list">
      <div class="prof-item" onclick="setPlayer(null)">Guest Mode</div>
    </div>
    <div class="modal-h" style="margin-top:1rem">New Profile</div>
    <div class="prof-form">
      <input type="text" id="pFirst" class="prof-input" placeholder="First Name">
      <input type="text" id="pLast" class="prof-input" placeholder="Last Name">
      <button class="prof-submit" onclick="createProfile()">Create & Select</button>
    </div>
  </div>
</div>

<script>
let audioTimer=null, audioEditingUntil=0;

// ── Profiles ─────────────────────────────────────────────────────────────────
async function openProfiles(){
  document.getElementById('profModal').style.display='flex';
  const r=await fetch('/profiles');
  const d=await r.json();
  const list=document.getElementById('profList');
  list.innerHTML='<div class="prof-item" onclick="setPlayer(null)">Guest Mode</div>';
  d.profiles.forEach(p=>{
    const div=document.createElement('div');
    div.className='prof-item';
    div.textContent=p.first_name+' '+p.last_name;
    div.onclick=()=>setPlayer(p.id);
    list.appendChild(div);
  });
}
function closeProfiles(){ document.getElementById('profModal').style.display='none'; }
async function createProfile(){
  const f=document.getElementById('pFirst').value,l=document.getElementById('pLast').value;
  if(!f||!l)return;
  const r=await fetch('/profiles',{method:'POST',headers:{'Content-Type':'application/json'},
                                    body:JSON.stringify({first_name:f,last_name:l})});
  const d=await r.json();
  if(d.ok){ document.getElementById('pFirst').value='';document.getElementById('pLast').value=''; setPlayer(d.id); }
}
async function setPlayer(id){
  const r=await fetch('/set_player',{method:'POST',headers:{'Content-Type':'application/json'},
                                     body:JSON.stringify({id})});
  const d=await r.json();
  closeProfiles();
  poll(); // refresh immediately
}

// ── Scene buttons ────────────────────────────────────────────────────────────
async function loadScene(name){
  document.getElementById('sceneName').textContent='Requesting '+name+'…';
  const r=await fetch('/scene',{method:'POST',headers:{'Content-Type':'application/json'},
                                body:JSON.stringify({scene:name})});
  if(!r.ok) document.getElementById('sceneName').textContent='Scene request failed';
}
function hilite(scene){
  document.querySelectorAll('.sb').forEach(b=>b.classList.toggle('active',b.dataset.scene===scene));
}

// ── Audio sliders ────────────────────────────────────────────────────────────
function sliderMoved(){
  clearTimeout(audioTimer); audioEditingUntil=Date.now()+600;
  const fl=parseInt(document.getElementById('floorSlider').value)/1000;
  const cl=parseInt(document.getElementById('ceilSlider').value)/1000;
  document.getElementById('floorVal').textContent=fl.toFixed(3);
  document.getElementById('ceilVal').textContent=cl.toFixed(3);
  if(fl>=cl){document.getElementById('operatorError').textContent='Floor must be below ceiling';return}
  audioTimer=setTimeout(()=>postJson('/audio',{floor:fl,ceil:cl}),180);
}

// ── Clear cursors ────────────────────────────────────────────────────────────
async function clearCursors(){
  await fetch('/clear_cursors',{method:'POST'});
}

// ── Status poll ──────────────────────────────────────────────────────────────
async function poll(){
  try{
    const r=await fetch('/status');
    const d=await r.json();
    document.getElementById('conn').className='conn'+(d.godot_connected?' live':'');
    const confirmed=d.scene||'No scene confirmation';
    document.getElementById('sceneName').textContent=d.pending_scene
      ? confirmed+' · Loading '+d.pending_scene
      : confirmed;
    hilite(d.scene||'');
    document.getElementById('profDisplay').textContent='Hi, '+(d.player_name||'Guest')+'!';
    document.getElementById('runtimeStatus').textContent=
      (d.godot_connected?'Godot connected':'Godot not confirmed')+' · Camera '+(d.camera||'unknown')+
      ' · Calibration '+(d.calibration||'unknown')+(d.scene_error?' · '+d.scene_error:'');
    document.getElementById('diagnosticsDetail').textContent=
      'Camera '+(d.camera||'unknown')+' · '+(d.tracker||'unknown')+' · '+(d.detections||0)+
      ' detections · Godot '+(d.godot_connected?'connected':'not confirmed');
    document.getElementById('afill').style.width=(d.audio_level*100)+'%';
    document.getElementById('detTxt').textContent=(d.detections||0)+' pts';
    const u=d.uptime_s||0,mm=String(Math.floor(u/60)).padStart(2,'0'),ss=String(u%60).padStart(2,'0');
    document.getElementById('uptimeTxt').textContent=mm+':'+ss;
    // Sync audio sliders only if not being touched
    if(Date.now()>audioEditingUntil&&document.activeElement!==document.getElementById('floorSlider')&&d.audio_floor!==undefined){
      document.getElementById('floorSlider').value=Math.round(d.audio_floor*1000);
      document.getElementById('floorVal').textContent=d.audio_floor.toFixed(3);
    }
    if(Date.now()>audioEditingUntil&&document.activeElement!==document.getElementById('ceilSlider')&&d.audio_ceil!==undefined){
      document.getElementById('ceilSlider').value=Math.round(d.audio_ceil*1000);
      document.getElementById('ceilVal').textContent=d.audio_ceil.toFixed(3);
    }
  }catch(e){document.getElementById('conn').className='conn';}
}
let page='play', operatorData=null, previewTimer=null, previewGeneration=0, settingTimers={}, audioPollBusy=false, objectCorner=null, selectingObject=false;
let pendingTracker=null, trackerRequestTime=0, renderedTracker=null;
function showPage(name){
  page=name;
  document.querySelectorAll('.operator-page').forEach(el=>el.hidden=el.id!=='page-'+name);
  document.getElementById('nav-play').classList.toggle('active',name==='play');
  document.getElementById('nav-settings').classList.toggle('active',name!=='play');
  document.getElementById('settingsNav').hidden=name==='play';
  document.querySelectorAll('#settingsNav button').forEach(el=>el.classList.toggle('active',el.dataset.page===name));
  previewGeneration++;
  clearTimeout(previewTimer);
  if(name!=='tracking'){selectingObject=false;objectCorner=null}
  if(name==='tracking'||name==='calibration') updatePreview();
  if(name==='settings') refreshPresets();
  refreshOperator();
}
async function postJson(url,data){
  try{
    const r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});
    const result=await r.json();
    if(!r.ok) throw new Error(result.error||'Request failed');
    document.getElementById('operatorError').textContent='';
    return result;
  }catch(e){document.getElementById('operatorError').textContent=e.message; return null}
}
async function updatePreview(){
  if(document.hidden||!(page==='tracking'||page==='calibration')) return;
  const generation=previewGeneration;
  const mode=page==='calibration'?'overlay':document.getElementById('previewMode').value;
  const image=document.getElementById(page==='calibration'?'calPreview':'trackingPreview');
  try{
    const response=await fetch('/preview/'+mode,{cache:'no-store'});
    if(response.ok){
      const blob=await response.blob();
      if(generation!==previewGeneration)return;
      const old=image.dataset.url;
      const url=URL.createObjectURL(blob); image.src=url; image.dataset.url=url;
      image.dataset.context=response.headers.get('X-LightTable-Context')||'';
      if(old) URL.revokeObjectURL(old);
    }else if(generation===previewGeneration)image.removeAttribute('src');
  }catch(e){if(generation===previewGeneration)image.removeAttribute('src')}
  if(generation===previewGeneration&&(page==='tracking'||page==='calibration'))
    previewTimer=setTimeout(updatePreview,Number(document.getElementById('previewRate').value));
}
document.addEventListener('visibilitychange',()=>{
  previewGeneration++; clearTimeout(previewTimer); if(!document.hidden) updatePreview();
});
function makeControl(name,spec,isTracker){
  const trackerName=operatorData.tracker_name;
  const row=document.createElement('div'); row.className='oprow';
  const label=document.createElement('label'); label.textContent=name.replaceAll('_',' '); row.appendChild(label);
  let input;
  if(spec.options){
    input=document.createElement('select');
    spec.options.forEach(value=>{const option=document.createElement('option');option.value=value;option.textContent=value;input.appendChild(option)});
    input.value=spec.value;
  }else{
    input=document.createElement('input'); input.type=spec.type==='boolean'?'checkbox':'range';
    if(input.type==='checkbox')input.checked=spec.value;
    else {input.min=spec.min;input.max=spec.max;input.step=1;input.value=spec.value}
  }
  const out=document.createElement('output'); out.textContent=String(spec.value);
  input.oninput=()=>{
    const value=input.type==='checkbox'?input.checked:(input.type==='range'?Number(input.value):input.value);
    out.textContent=String(value);
    clearTimeout(settingTimers[name]);
    settingTimers[name]=setTimeout(()=>{
      const payload={settings:{},tracker_settings:{},tracker_name:trackerName};
      payload[isTracker?'tracker_settings':'settings'][name]=value;
      postJson('/operator/settings',payload);
    },180);
  };
  row.appendChild(input);row.appendChild(out);return row;
}
async function chooseTracker(value){
  if(!operatorData)return;
  pendingTracker=value; trackerRequestTime=Date.now();
  document.getElementById('trackerSelect').disabled=true;
  document.getElementById('trackerStatus').textContent='Switching to '+value+'…';
  document.getElementById('trackerControls').replaceChildren();
  renderedTracker=null;
  const result=await postJson('/operator/settings',{settings:{tracker:value},tracker_settings:{},tracker_name:operatorData.tracker_name});
  if(!result)pendingTracker=null;
  refreshOperator();
}
async function refreshOperator(){
  try{
    const response=await fetch('/operator',{cache:'no-store'}); if(!response.ok)throw new Error('Operator status unavailable');
    operatorData=await response.json();
    document.getElementById('objectControls').hidden=operatorData.tracker_name!=='Object Tracking (CSRT)';
    if(operatorData.message)document.getElementById('operatorError').textContent=operatorData.message;
    if(page==='tracking'){
      const spec=operatorData.settings.tracker, select=document.getElementById('trackerSelect');
      if(!select.options.length)spec.options.forEach(value=>{const option=document.createElement('option');option.value=value;option.textContent=value;select.appendChild(option)});
      if(pendingTracker && ((spec.value===pendingTracker && operatorData.tracker_ready) ||
          (operatorData.message||'').startsWith('Could not initialize ') || Date.now()-trackerRequestTime>5000)){
        if(spec.value!==pendingTracker || !operatorData.tracker_ready)
          document.getElementById('operatorError').textContent=(operatorData.message||'').startsWith('Could not initialize ')
            ? operatorData.message : 'Tracker switch timed out';
        pendingTracker=null;
      }
      select.disabled=!!pendingTracker;
      select.value=pendingTracker||spec.value;
      const trackerControls=document.getElementById('trackerControls');
      const ready=!pendingTracker && operatorData.tracker_ready;
      document.getElementById('trackerStatus').textContent=ready
        ? operatorData.tracker_name+' settings' : 'Switching tracker…';
      if(ready && (renderedTracker!==operatorData.tracker_name ||
          !trackerControls.querySelector('input:focus, select:focus'))){
        trackerControls.replaceChildren();
        const entries=Object.entries(operatorData.tracker_settings);
        entries.forEach(([name,control])=>trackerControls.appendChild(makeControl(name,control,true)));
        if(!entries.length)trackerControls.textContent='No additional settings for this tracker.';
        renderedTracker=operatorData.tracker_name;
      }else if(!ready){trackerControls.replaceChildren();renderedTracker=null}
    }
    if(page==='tracking'&&!document.querySelector('#trackingControls input:focus, #trackingControls select:focus')){
      const container=document.getElementById('trackingControls');container.replaceChildren();
      for(const [name,spec] of Object.entries(operatorData.settings))if(name!=='tracker')container.appendChild(makeControl(name,spec,false));
    }
    const cal=operatorData.calibration;
    document.getElementById('calStatus').textContent=cal.state+': '+cal.message+' · '+
      cal.points.length+' points '+cal.points.map(p=>'('+p[0]+', '+p[1]+')').join(' ');
    const profiles=document.getElementById('calProfiles'), oldProfile=profiles.value;
    profiles.replaceChildren();
    (cal.profiles||[]).forEach(profile=>{const option=document.createElement('option');option.value=profile.id;
      option.textContent=profile.name+(profile.compatible?'':' (incompatible)');option.disabled=!profile.compatible;profiles.appendChild(option)});
    if(oldProfile)profiles.value=oldProfile;
    document.getElementById('diagnosticsText').textContent=
      'Capture '+operatorData.capture_fps.toFixed(1)+' fps · Processing '+operatorData.processing_fps.toFixed(1)+
      ' fps · UDP '+operatorData.udp;
  }catch(e){document.getElementById('operatorError').textContent='Operator status unavailable'}
}
async function refreshPresets(){
  try{
    const r=await fetch('/operator/presets'),d=await r.json();if(!r.ok)throw new Error(d.error);
    const list=document.getElementById('presetList'), old=list.value;list.replaceChildren();
    d.presets.forEach(name=>{const option=document.createElement('option');option.value=name;option.textContent=name;list.appendChild(option)});
    if(d.presets.includes(old))list.value=old;
  }catch(e){document.getElementById('operatorError').textContent=e.message}
}
async function presetAction(action){
  let name=document.getElementById('presetList').value,new_name;
  if(action==='save')name=prompt('Name for current environment');
  if(!name)return;
  if(action==='rename'){new_name=prompt('New preset name',name);if(!new_name)return}
  if(action==='delete'&&!confirm('Delete preset '+name+'?'))return;
  const result=await postJson('/operator/presets',{action,name,new_name});
  if(result){if(result.message)document.getElementById('operatorError').textContent=result.message;refreshPresets()}
}
async function lifecycle(action){
  if(!confirm((action==='restart'?'Restart':'Stop')+' the CV and remote process? Godot will remain running.'))return;
  const result=await postJson('/operator/lifecycle',{action,confirm:true});
  if(result)document.getElementById('operatorError').textContent='Request accepted; connection will close.';
}
['start','undo','cancel','reset','save','load'].forEach(action=>{
  const button=document.createElement('button');button.className='opbutton';button.textContent=action;
  button.onclick=()=>postJson('/operator/calibration',{action,profile:document.getElementById('calProfiles').value});document.getElementById('calButtons').appendChild(button);
});
function calibrationPoint(event){
  if(!operatorData||operatorData.calibration.state!=='selecting')return;
  const rect=event.currentTarget.getBoundingClientRect();
  const x=(event.clientX-rect.left)/rect.width,y=(event.clientY-rect.top)/rect.height;
  postJson('/operator/calibration',{action:'point',x,y,context:event.currentTarget.dataset.context});
}
function beginObjectSelection(){
  document.getElementById('previewMode').value='camera';
  objectCorner=null; selectingObject=true;
  document.getElementById('operatorError').textContent='Tap top-left then bottom-right of the object.';
}
document.getElementById('trackingPreview').addEventListener('click',event=>{
  if(!selectingObject)return;
  const rect=event.currentTarget.getBoundingClientRect();
  const point={x:(event.clientX-rect.left)/rect.width,y:(event.clientY-rect.top)/rect.height};
  if(!objectCorner){objectCorner=point;return}
  const x=Math.min(point.x,objectCorner.x),y=Math.min(point.y,objectCorner.y);
  const width=Math.abs(point.x-objectCorner.x),height=Math.abs(point.y-objectCorner.y);
  selectingObject=false;
  postJson('/operator/object',{action:'add',x,y,width,height,context:event.currentTarget.dataset.context});
});
async function pollAudio(){
  if(document.hidden||page!=='diagnostics'||audioPollBusy)return;
  audioPollBusy=true;
  try{
    const r=await fetch('/status',{cache:'no-store'}), d=await r.json();
    const fresh=d.audio_fresh && d.audio_status, active=fresh&&d.audio_status==='active';
    document.getElementById('micStatus').textContent=fresh?'Microphone: '+d.audio_status:'Godot telemetry unavailable';
    for(const [key,id] of [['audio_raw','raw'],['audio_level','mapped']]){
      const v=active&&typeof d[key]==='number'?d[key]:0;
      document.getElementById(id+'Meter').value=v;
      document.getElementById(id+'Value').textContent=active?v.toFixed(3):'—';
    }
    if(active && Date.now()>audioEditingUntil){
      for(const [key,id] of [['audio_floor','floor'],['audio_ceil','ceil']]){
        if(typeof d[key]==='number'){
          document.getElementById(id+'Slider').value=Math.round(d[key]*1000);
          document.getElementById(id+'Val').textContent=d[key].toFixed(3);
          document.getElementById(id+'Marker').style.left=(d[key]*100)+'%';
        }
      }
    }
  }catch(e){document.getElementById('micStatus').textContent='Status unavailable'}
  finally{audioPollBusy=false}
}
poll(); refreshOperator(); setInterval(poll,3000); setInterval(refreshOperator,1000); setInterval(pollAudio,100);
</script>
</body></html>"""


# ─────────────────────────────────────────────────────────────────────────────
# WebRemote
# ─────────────────────────────────────────────────────────────────────────────
class WebRemote:
    """
    Flask-based phone remote.  Call start() once; it runs in a daemon thread.

    Parameters
    ----------
    state       : ControlState shared with the CV main loop
    godot_host  : Godot's UDP listener address (usually 127.0.0.1)
    godot_port  : Godot's UDP port (7000)
    """

    def __init__(
        self,
        state: ControlState,
        godot_host: str = "127.0.0.1",
        godot_port: int  = 7000,
    ):
        self._state       = state
        self._godot_host  = godot_host
        self._godot_port  = godot_port
        self._cfg         = _load_config()
        self._port        = int(self._cfg.get("port", 5000))
        self._udp_socket = None
        self._stop_event = threading.Event()
        self._server = None
        self._server_thread = None
        self._status_thread = None
        self._login_attempts = {}
        self._login_lock = threading.Lock()
        self._presets = EnvironmentPresets()

    # ── UDP helper ────────────────────────────────────────────────────────────
    def _send_godot(self, data: dict) -> None:
        """Send a UDP command from the status-listener port when available."""
        payload = json.dumps(data).encode()
        if self._udp_socket is not None:
            self._udp_socket.sendto(payload, (self._godot_host, self._godot_port))
        else:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.sendto(payload, (self._godot_host, self._godot_port))

    def _listen_godot_status(self):
        next_request = 0.0
        disconnected_reported = False
        while not self._stop_event.is_set():
            try:
                now = time.monotonic()
                if now >= next_request:
                    request_packet = json.dumps({
                        "type": "command", "cmd": "status_request"
                    }).encode("utf-8")
                    self._udp_socket.sendto(
                        request_packet, (self._godot_host, self._godot_port)
                    )
                    next_request = now + 0.1
                payload, sender = self._udp_socket.recvfrom(65535)
                if sender[0] != "127.0.0.1":
                    continue
                data = json.loads(payload.decode("utf-8"))
                if isinstance(data, dict) and data.get("type") == "godot_status":
                    self._state.update_godot_status(data)
                    disconnected_reported = False
            except socket.timeout:
                continue
            except ConnectionResetError:
                if not disconnected_reported:
                    print("[WebRemote] Godot is not responding; continuing to retry.")
                    disconnected_reported = True
            except OSError as exc:
                if not self._stop_event.is_set():
                    print(f"[WebRemote] Godot status listener stopped: {exc}")
                return
            except (UnicodeDecodeError, ValueError):
                print("[WebRemote] Ignored malformed Godot status datagram")

    # ── Page builder ──────────────────────────────────────────────────────────
    def _build_main_page(self) -> str:
        scene_btns = "\n".join(
            f'<button class="sb" data-scene="{s}" ontouchstart="" onclick=\'loadScene({json.dumps(s)})\'>{s}</button>'
            for s in SCENES
        )
        tracker_opts = "\n".join(
            f'<option value="{i}">{t}</option>'
            for i, t in enumerate(TRACKER_NAMES)
        )
        return (
            _MAIN_HTML
            .replace("%%SCENE_BUTTONS%%", scene_btns)
            .replace("%%TRACKER_OPTIONS%%", tracker_opts)
        )

    # ── Flask app ─────────────────────────────────────────────────────────────
    def _create_app(self) -> Flask:
        app = Flask(__name__)
        app.secret_key                  = self._cfg["secret_key"]
        app.permanent_session_lifetime  = timedelta(hours=8)
        app.config.update(
            SESSION_COOKIE_SAMESITE='Strict',
            SESSION_COOKIE_SECURE=False,
            SESSION_COOKIE_HTTPONLY=True,
            MAX_CONTENT_LENGTH=65536,
        )

        pin_cfg = str(self._cfg["pin"])
        state   = self._state
        remote  = self

        @app.before_request
        def _same_origin_posts():
            if request.method == "POST":
                origin = request.headers.get("Origin")
                if origin and urlsplit(origin).netloc.lower() != request.host.lower():
                    return jsonify({"ok": False, "error": "cross-origin request rejected"}), 403

        def _authed() -> bool:
            return session.get("authed") is True

        # ── Login ─────────────────────────────────────────────────────────────
        @app.get("/login")
        def login_page():
            if _authed():
                return redirect(url_for("index"))
            return _LOGIN_HTML, 200, {"Content-Type": "text/html"}

        @app.post("/login")
        def login_post():
            data = request.get_json(silent=True) or {}
            if not isinstance(data, dict):
                return jsonify({"ok": False, "error": "invalid request"}), 400
            pin = data.get("pin", "")
            client = request.remote_addr or "unknown"
            now = time.monotonic()
            with remote._login_lock:
                if client not in remote._login_attempts and len(remote._login_attempts) >= 1024:
                    oldest = min(remote._login_attempts, key=lambda key: remote._login_attempts[key][-1]
                                 if remote._login_attempts[key] else 0)
                    del remote._login_attempts[oldest]
                attempts = remote._login_attempts.setdefault(client, deque())
                while attempts and now - attempts[0] > 60:
                    attempts.popleft()
                if len(attempts) >= 5:
                    return jsonify({"ok": False, "error": "too many attempts"}), 429
                valid_pin = isinstance(pin, str) and pin.isascii() and pin.isdigit() and 4 <= len(pin) <= 12
                ok = valid_pin and secrets.compare_digest(pin, pin_cfg)
                if ok:
                    attempts.clear()
                else:
                    attempts.append(now)
            if ok:
                session.clear()
                session.permanent = True
                session["authed"] = True
            return jsonify({"ok": ok})

        @app.get("/logout")
        def logout():
            session.clear()
            return redirect(url_for("login_page"))

        # ── Main page ─────────────────────────────────────────────────────────
        @app.get("/")
        def index():
            if not _authed():
                return redirect(url_for("login_page"))
            return remote._build_main_page(), 200, {"Content-Type": "text/html"}

        # ── Export ────────────────────────────────────────────────────────────
        @app.get("/export")
        def export_data():
            if not _authed():
                return jsonify({"ok": False}), 401
            profiles = _load_profiles().get("profiles", [])
            lines = ["PLAYER PROFILES EXPORT", "======================", ""]
            for p in profiles:
                lines.append(f"ID: {p['id']}")
                lines.append(f"Name: {p['first_name']} {p['last_name']}")
                lines.append(f"Created: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(p['created_at']))}")
                lines.append("-" * 20)
            
            from flask import Response
            return Response("\n".join(lines), mimetype="text/plain",
                            headers={"Content-Disposition": "attachment;filename=lighttable_profiles.txt"})

        # ── Profiles ─────────────────────────────────────────────────────────
        @app.get("/profiles")
        def get_profiles():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            return jsonify(_load_profiles())

        @app.post("/profiles")
        def create_profile():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            data = request.get_json(silent=True) or {}
            if not isinstance(data, dict):
                return jsonify({"ok": False, "error": "invalid request"}), 400
            first = data.get("first_name", "")
            last = data.get("last_name", "")
            if not isinstance(first, str) or not isinstance(last, str):
                return jsonify({"ok": False, "error": "names must be text"}), 400
            first, last = first.strip(), last.strip()
            if not first or not last or len(first) > 40 or len(last) > 40:
                return jsonify({"ok": False, "error": "Name required"}), 400
            
            profiles_data = _load_profiles()
            new_id = secrets.token_hex(4)
            profiles_data["profiles"].append({
                "id": new_id,
                "first_name": first,
                "last_name": last,
                "created_at": time.time()
            })
            if not _save_profiles(profiles_data):
                return jsonify({"ok": False, "error": "profile could not be saved"}), 500
            return jsonify({"ok": True, "id": new_id})

        @app.post("/set_player")
        def set_player():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            data = request.get_json(silent=True) or {}
            if not isinstance(data, dict):
                return jsonify({"ok": False, "error": "invalid request"}), 400
            pid = data.get("id")
            if pid is not None and not isinstance(pid, str):
                return jsonify({"ok": False, "error": "invalid player id"}), 400
            if not pid:
                state.set_player(None, "Guest")
                return jsonify({"ok": True})
            
            profiles_data = _load_profiles()
            p = next((x for x in profiles_data["profiles"] if x["id"] == pid), None)
            if p:
                state.set_player(pid, f"{p['first_name']} {p['last_name']}")
                return jsonify({"ok": True, "name": p['first_name']})
            return jsonify({"ok": False, "error": "not found"}), 404

        # ── Commands ─────────────────────────────────────────────────────────
        @app.post("/scene")
        def set_scene():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            data = request.get_json(silent=True) or {}
            if not isinstance(data, dict):
                return jsonify({"ok": False, "error": "invalid request"}), 400
            name = data.get("scene", "")
            if not isinstance(name, str) or name not in SCENE_SCRIPTS:
                return jsonify({"ok": False, "error": "unknown scene"}), 400
            request_id = secrets.token_hex(6)
            state.set_scene_name(name, request_id)
            try:
                remote._send_godot({
                    "type": "command",
                    "cmd": "load_scene",
                    "scene": name,
                    "script": SCENE_SCRIPTS[name],
                    "request_id": request_id,
                })
            except OSError as exc:
                state.fail_scene_request(request_id)
                print(f"[WebRemote] Could not send scene request: {exc}")
                return jsonify({"ok": False, "error": "Godot command could not be sent"}), 503
            return jsonify({"ok": True, "pending": True})

        @app.post("/tracker")
        def set_tracker():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            data = request.get_json(silent=True) or {}
            if not isinstance(data, dict):
                return jsonify({"ok": False, "error": "invalid request"}), 400
            try:
                idx = int(data["tracker_idx"])
            except (TypeError, ValueError, KeyError):
                return jsonify({"ok": False, "error": "invalid tracker index"}), 400
            if not 0 <= idx < len(TRACKER_NAMES):
                return jsonify({"ok": False, "error": "invalid tracker index"}), 400
            state.request_tracker(idx)
            return jsonify({"ok": True})

        @app.post("/audio")
        def set_audio():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            data = request.get_json(silent=True) or {}
            if not isinstance(data, dict):
                return jsonify({"ok": False, "error": "invalid request"}), 400
            try:
                fl = float(data["floor"])
                cl = float(data["ceil"])
            except (KeyError, TypeError, ValueError, OverflowError):
                return jsonify({"ok": False, "error": "audio levels must be numbers"}), 400
            if not math.isfinite(fl) or not math.isfinite(cl) or not 0 <= fl < cl <= 1:
                return jsonify({"ok": False, "error": "audio range must satisfy 0 <= floor < ceiling <= 1"}), 400
            if not state.get_status()["audio_fresh"]:
                return jsonify({"ok": False, "error": "Godot audio settings unavailable"}), 503
            try:
                remote._send_godot({"type": "command", "cmd": "set_audio",
                                    "floor": fl, "ceiling": cl})
            except OSError as exc:
                print(f"[WebRemote] Could not send audio command: {exc}")
                return jsonify({"ok": False, "error": "Godot command could not be sent"}), 503
            return jsonify({"ok": True, "pending": True})

        @app.post("/clear_cursors")
        def clear_cursors():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            try:
                remote._send_godot({"type": "command", "cmd": "clear_cursors"})
            except OSError as exc:
                print(f"[WebRemote] Could not send clear-cursors command: {exc}")
                return jsonify({"ok": False, "error": "Godot command could not be sent"}), 503
            return jsonify({"ok": True})

        # ── Status ────────────────────────────────────────────────────────────
        @app.get("/status")
        def get_status():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            st = state.get_status()
            return jsonify(st)

        @app.get("/preview/<mode>")
        def preview(mode):
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            if mode not in OperatorPreview.MODES:
                return jsonify({"ok": False, "error": "unknown preview"}), 400
            result = state.preview.request(mode)
            if result is None:
                return jsonify({"ok": False, "error": "preview waiting for camera"}), 503
            image, context = result
            from flask import Response
            return Response(image, mimetype="image/jpeg",
                            headers={"Cache-Control": "no-store, private",
                                     "X-LightTable-Context": context})

        @app.get("/operator")
        def operator_status():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            snapshot = state.operator_snapshot()
            if snapshot is None:
                return jsonify({"ok": False, "error": "application starting"}), 503
            return jsonify(snapshot)

        @app.post("/operator/lifecycle")
        def operator_lifecycle():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            data = request.get_json(silent=True)
            if not isinstance(data, dict) or data.get("confirm") is not True or data.get("action") not in ("shutdown", "restart"):
                return jsonify({"ok": False, "error": "confirmation and valid action required"}), 400
            if not state.queue_operator({"type": "lifecycle", "action": data["action"]}):
                return jsonify({"ok": False, "error": "application busy"}), 503
            return jsonify({"ok": True, "pending": True})

        @app.post("/operator/object")
        def operator_object():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            data = request.get_json(silent=True)
            snapshot = state.operator_snapshot()
            if not isinstance(data, dict) or snapshot is None or data.get("action") not in ("add", "clear"):
                return jsonify({"ok": False, "error": "invalid object request"}), 400
            if snapshot["tracker_name"] != "Object Tracking (CSRT)":
                return jsonify({"ok": False, "error": "select Object tracker first"}), 409
            cal = snapshot["calibration"]
            command = {"type": "object", "action": data["action"], "signature": cal["signature"]}
            if data["action"] == "add":
                if not cal["camera_connected"] or data.get("context") != cal["context"]:
                    return jsonify({"ok": False, "error": "camera preview is stale"}), 409
                for key in ("x", "y", "width", "height"):
                    value = data.get(key)
                    if type(value) not in (int, float) or not 0 <= value <= 1:
                        return jsonify({"ok": False, "error": "invalid object region"}), 400
                    command[key] = value
                if (command["width"] < 0.01 or command["height"] < 0.01 or
                        command["x"] + command["width"] > 1 or command["y"] + command["height"] > 1):
                    return jsonify({"ok": False, "error": "invalid object region"}), 400
            if not state.queue_operator(command):
                return jsonify({"ok": False, "error": "application busy"}), 503
            return jsonify({"ok": True, "pending": True})

        @app.post("/operator/settings")
        def operator_settings():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            data = request.get_json(silent=True)
            snapshot = state.operator_snapshot()
            if not isinstance(data, dict) or snapshot is None:
                return jsonify({"ok": False, "error": "settings unavailable"}), 400
            values = data.get("settings", {})
            tracker_values = data.get("tracker_settings", {})
            if not isinstance(values, dict) or not isinstance(tracker_values, dict):
                return jsonify({"ok": False, "error": "settings must be objects"}), 400
            if tracker_values and data.get("tracker_name") != snapshot["tracker_name"]:
                return jsonify({"ok": False, "error": "tracker has changed"}), 409
            try:
                _validate_operator_values(values, snapshot["settings"])
                _validate_operator_values(tracker_values, snapshot["tracker_settings"])
            except ValueError as exc:
                return jsonify({"ok": False, "error": str(exc)}), 400
            if "tracker" in values and tracker_values:
                return jsonify({"ok": False, "error": "change tracker before its parameters"}), 400
            if not state.queue_operator({"type": "settings", "settings": values,
                                         "tracker_settings": tracker_values,
                                         "tracker_name": snapshot["tracker_name"]}):
                return jsonify({"ok": False, "error": "application busy"}), 503
            return jsonify({"ok": True, "pending": True})

        @app.get("/operator/presets")
        def list_environment_presets():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            try:
                return jsonify({"presets": remote._presets.list()})
            except (OSError, ValueError) as exc:
                return jsonify({"ok": False, "error": str(exc)}), 500

        @app.post("/operator/presets")
        def environment_presets():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            data = request.get_json(silent=True)
            if not isinstance(data, dict):
                return jsonify({"ok": False, "error": "invalid request"}), 400
            action, name = data.get("action"), data.get("name")
            if action not in ("save", "load", "rename", "delete") or not EnvironmentPresets.validate_name(name):
                return jsonify({"ok": False, "error": "invalid action or name"}), 400
            snapshot = state.operator_snapshot()
            try:
                if action == "save":
                    if snapshot is None:
                        raise ValueError("Application is not ready")
                    if not snapshot.get("tracker_ready"):
                        raise ValueError("Wait for the tracker change to finish")
                    status = state.get_status()
                    if not status["audio_fresh"] or "audio_floor" not in status or "audio_ceil" not in status:
                        raise ValueError("Godot audio settings are not available")
                    preset = {
                        "settings": {k: v["value"] for k, v in snapshot["settings"].items()},
                        "tracker_name": snapshot["tracker_name"],
                        "tracker_settings": {k: v["value"] for k, v in snapshot["tracker_settings"].items()},
                        "calibration_signature": snapshot["calibration"]["signature"],
                        "audio_floor": status["audio_floor"], "audio_ceil": status["audio_ceil"],
                    }
                    remote._presets.save(name, preset)
                elif action == "rename":
                    new_name = data.get("new_name")
                    if not EnvironmentPresets.validate_name(new_name):
                        raise ValueError("Invalid new name")
                    remote._presets.rename(name, new_name)
                elif action == "delete":
                    remote._presets.delete(name)
                else:
                    preset = remote._presets.get(name)
                    if snapshot is None or not isinstance(preset, dict):
                        raise ValueError("Preset not found or application not ready")
                    if not state.get_status()["audio_fresh"]:
                        return jsonify({"ok": False, "error": "Godot audio settings unavailable"}), 503
                    _validate_operator_values(preset.get("settings"), snapshot["settings"])
                    if ("tracker" not in preset["settings"] or
                            not isinstance(preset.get("tracker_name"), str)):
                        raise ValueError("Invalid saved tracker")
                    tracker_values = preset.get("tracker_settings")
                    if not isinstance(tracker_values, dict) or any(
                        not isinstance(k, str) or type(v) is not int or v < 0 or v > 50000
                        for k, v in tracker_values.items()
                    ):
                        raise ValueError("Invalid saved tracker settings")
                    floor, ceiling = preset.get("audio_floor"), preset.get("audio_ceil")
                    if (type(floor) not in (int, float) or type(ceiling) not in (int, float)
                            or not 0 <= floor < ceiling <= 1):
                        raise ValueError("Invalid saved audio range")
                    command = {"type": "preset", "preset": preset}
                    if not state.queue_operator(command):
                        return jsonify({"ok": False, "error": "application busy"}), 503
                    return jsonify({"ok": True, "pending": True,
                                    "message": "Calibration will only load if the camera configuration matches."})
                return jsonify({"ok": True})
            except ValueError as exc:
                return jsonify({"ok": False, "error": str(exc)}), 400
            except OSError as exc:
                print(f"[WebRemote] Preset operation failed: {exc}")
                return jsonify({"ok": False, "error": "Preset storage or Godot command failed"}), 503

        @app.post("/operator/calibration")
        def operator_calibration():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            data = request.get_json(silent=True)
            snapshot = state.operator_snapshot()
            if not isinstance(data, dict) or snapshot is None:
                return jsonify({"ok": False, "error": "calibration unavailable"}), 400
            action = data.get("action")
            if action not in ("start", "undo", "reset", "cancel", "save", "load", "point"):
                return jsonify({"ok": False, "error": "invalid action"}), 400
            command = {"type": "calibration", "action": action,
                       "signature": snapshot["calibration"]["signature"]}
            if command["signature"] is None:
                return jsonify({"ok": False, "error": "camera is not ready"}), 409
            if action == "load":
                profile_id = data.get("profile")
                if not any(profile["id"] == profile_id and profile["compatible"]
                           for profile in snapshot["calibration"].get("profiles", [])):
                    return jsonify({"ok": False, "error": "select a compatible profile"}), 409
            if action == "point":
                if snapshot["calibration"]["state"] != "selecting":
                    return jsonify({"ok": False, "error": "start calibration first"}), 409
                if (not snapshot["calibration"].get("camera_connected") or
                        data.get("context") != snapshot["calibration"].get("context")):
                    return jsonify({"ok": False, "error": "preview is stale or camera is disconnected"}), 409
                for key in ("x", "y"):
                    value = data.get(key)
                    if type(value) not in (int, float) or not 0 <= value < 1:
                        return jsonify({"ok": False, "error": "invalid point"}), 400
                    command[key] = value
            if not state.queue_operator(command):
                return jsonify({"ok": False, "error": "application busy"}), 503
            return jsonify({"ok": True, "pending": True})

        return app

    def _generate_qr(self, url: str) -> None:
        """Write QR PNG to visual_layer/assets/remote_qr.png next to the project."""
        try:
            import qrcode as _qr
            qr = _qr.QRCode(box_size=7, border=2)
            qr.add_data(url)
            qr.make(fit=True)
            img = qr.make_image(fill_color="#ffffff", back_color="#000000")
            out = Path(__file__).parent.parent / "visual_layer" / "assets" / "remote_qr.png"
            out.parent.mkdir(parents=True, exist_ok=True)
            img.save(str(out))
        except (ImportError, OSError, TypeError, ValueError) as e:
            print(f"[WebRemote] QR generation skipped: {e}")

    # ── Public API ────────────────────────────────────────────────────────────
    def start(self) -> None:
        """Start Flask in a background daemon thread."""
        app = self._create_app()
        url = self.get_url()
        self._generate_qr(url)
        print(f"[WebRemote] QR saved to visual_layer/assets/remote_qr.png")
        if self._cfg.get("generated_pin"):
            print(f"[WebRemote] A temporary six-digit PIN was generated for this run: {self._cfg['pin']}")
        try:
            self._udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._udp_socket.bind(("127.0.0.1", 7001))
            self._udp_socket.settimeout(1.0)
            self._status_thread = threading.Thread(
                target=self._listen_godot_status, name="GodotStatus", daemon=True
            )
            self._status_thread.start()
        except OSError as exc:
            if self._udp_socket is not None:
                self._udp_socket.close()
                self._udp_socket = None
            print(f"[WebRemote] Godot confirmation listener unavailable: {exc}")

        import logging
        from werkzeug.serving import make_server
        logging.getLogger("werkzeug").setLevel(logging.ERROR)
        self._server = make_server("0.0.0.0", self._port, app, threaded=True)
        self._server_thread = threading.Thread(target=self._server.serve_forever, name="WebRemote", daemon=True)
        self._server_thread.start()

    def stop(self):
        self._stop_event.set()
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            if self._server_thread:
                self._server_thread.join(timeout=2)
            self._server = None
        if self._udp_socket is not None:
            self._udp_socket.close()
        if self._status_thread:
            self._status_thread.join(timeout=2)
        self._udp_socket = None

    def get_url(self) -> str:
        return f"http://{_get_local_ip()}:{self._port}"
