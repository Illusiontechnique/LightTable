"""
web_remote.py  —  Flask phone remote for LightTable.

Runs in a background daemon thread started by main.py.
Open  http://<machine-ip>:5000  on any phone on the same WiFi/LAN.

PIN login (default 1234) — change in remote_config.json at project root.
The secret_key is auto-generated on first run and persisted so phone sessions
survive a CV-layer restart within the same day.

Commands are sent directly over UDP to Godot on port 7000 using the same
JSON-over-UDP protocol as the CV layer.

Tracker changes are handled via ControlState which the CV main loop polls
each frame.
"""

import json
import secrets
import socket
import threading
import time
from datetime import timedelta
from pathlib import Path

from flask import Flask, jsonify, redirect, request, session, url_for

# ─────────────────────────────────────────────────────────────────────────────
# Config  (remote_config.json at project root, one level above cv_layer/)
# ─────────────────────────────────────────────────────────────────────────────
_CFG_PATH = Path(__file__).parent.parent / "remote_config.json"
_DEFAULTS  = {"pin": "1234", "port": 5000}


def _load_config() -> dict:
    cfg = dict(_DEFAULTS)
    if _CFG_PATH.exists():
        try:
            with open(_CFG_PATH) as f:
                cfg.update(json.load(f))
        except Exception:
            pass
    if "secret_key" not in cfg:
        cfg["secret_key"] = secrets.token_hex(32)
        try:
            with open(_CFG_PATH, "w") as f:
                json.dump(cfg, f, indent=2)
        except Exception:
            pass
    return cfg


def _get_local_ip() -> str:
    """Best-effort: return the LAN IP that can reach external hosts."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except Exception:
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
                return json.load(f)
        except Exception:
            pass
    return {"profiles": []}


def _save_profiles(data: dict):
    try:
        with open(_PROFILES_PATH, "w") as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass


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
        self._pending_tracker: int | None = None
        self._t0              = time.monotonic()
        self._status = {
            "scene":       "None",
            "audio_level": 0.0,
            "tracker":     TRACKER_NAMES[0],
            "tracker_idx": 0,
            "uptime_s":    0,
            "detections":  0,
            "player_id":   None,
            "player_name": "Guest",
        }

    # ── Called by Flask thread ───────────────────────────────────────────────
    def request_tracker(self, idx: int):
        with self._lock:
            self._pending_tracker = idx

    def set_scene_name(self, name: str):
        with self._lock:
            self._status["scene"] = name

    def set_player(self, player_id: str | None, player_name: str = "Guest"):
        with self._lock:
            self._status["player_id"] = player_id
            self._status["player_name"] = player_name
            self._status["scene"] = name

    # ── Called by CV main loop ───────────────────────────────────────────────
    def pop_tracker_request(self) -> int | None:
        """Returns pending tracker index and clears it, or None."""
        with self._lock:
            idx = self._pending_tracker
            self._pending_tracker = None
            return idx

    def update_status(self, audio: float, tracker_idx: int, detections: int):
        with self._lock:
            self._status.update({
                "audio_level": round(audio, 3),
                "tracker":     TRACKER_NAMES[tracker_idx] if 0 <= tracker_idx < len(TRACKER_NAMES) else "?",
                "tracker_idx": tracker_idx,
                "uptime_s":    int(time.monotonic() - self._t0),
                "detections":  detections,
            })

    def get_status(self) -> dict:
        with self._lock:
            return dict(self._status)


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
function upd(){for(let i=0;i<4;i++)document.getElementById('d'+i).className='dot'+(i<pin.length?' on':'')}
function p(d){if(pin.length<4){pin+=d;upd();if(pin.length===4)setTimeout(go,200)}}
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

<div class="status-card">
  <div class="scene-now" id="sceneName">—</div>
  <div class="stat-row">
    <div class="abar"><div class="afill" id="afill"></div></div>
    <span id="detTxt">0 pts</span>
  </div>
</div>

<div class="sec">Scenes</div>
<div class="scene-grid">%%SCENE_BUTTONS%%</div>

<div class="sec">Tracking</div>
<div class="ctrl-card">
  <div class="crow">
    <span class="clbl">Tracker</span>
    <select id="trackerSel" onchange="setTracker(this.value)">%%TRACKER_OPTIONS%%</select>
  </div>
</div>

<div class="sec">Microphone</div>
<div class="ctrl-card">
  <div class="crow">
    <span class="clbl">Floor</span>
    <input type="range" id="floorSlider" min="0" max="100" value="1" oninput="sliderMoved()">
    <span class="cval" id="floorVal">0.01</span>
  </div>
  <div class="crow">
    <span class="clbl">Ceiling</span>
    <input type="range" id="ceilSlider" min="0" max="100" value="18" oninput="sliderMoved()">
    <span class="cval" id="ceilVal">0.18</span>
  </div>
</div>

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
let curScene='', audioTimer=null;

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
  curScene=name; hilite();
  await fetch('/scene',{method:'POST',headers:{'Content-Type':'application/json'},
                        body:JSON.stringify({scene:name})});
}
function hilite(){
  document.querySelectorAll('.sb').forEach(b=>b.classList.toggle('active',b.dataset.scene===curScene));
}

// ── Tracker ──────────────────────────────────────────────────────────────────
async function setTracker(v){
  await fetch('/tracker',{method:'POST',headers:{'Content-Type':'application/json'},
                           body:JSON.stringify({tracker_idx:parseInt(v)})});
}

// ── Audio sliders ────────────────────────────────────────────────────────────
function sliderMoved(){
  const fl=parseInt(document.getElementById('floorSlider').value)/100;
  const cl=parseInt(document.getElementById('ceilSlider').value)/100;
  document.getElementById('floorVal').textContent=fl.toFixed(2);
  document.getElementById('ceilVal').textContent=cl.toFixed(2);
  clearTimeout(audioTimer);
  audioTimer=setTimeout(()=>fetch('/audio',{method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({floor:fl,ceil:cl})}),380);
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
    document.getElementById('conn').className='conn live';
    if(d.scene&&d.scene!==curScene){curScene=d.scene;hilite();}
    document.getElementById('sceneName').textContent=d.scene||'—';
    document.getElementById('profDisplay').innerHTML = 'Hi, <b>' + (d.player_name || 'Guest') + '</b>!';
    document.getElementById('afill').style.width=(d.audio_level*100)+'%';
    document.getElementById('detTxt').textContent=(d.detections||0)+' pts';
    const u=d.uptime_s||0,mm=String(Math.floor(u/60)).padStart(2,'0'),ss=String(u%60).padStart(2,'0');
    document.getElementById('uptimeTxt').textContent=mm+':'+ss;
    const sel=document.getElementById('trackerSel');
    if(document.activeElement!==sel&&d.tracker_idx!==undefined)sel.value=d.tracker_idx;
    // Sync audio sliders only if not being touched
    if(document.activeElement!==document.getElementById('floorSlider')&&d.audio_floor!==undefined){
      document.getElementById('floorSlider').value=Math.round(d.audio_floor*100);
      document.getElementById('floorVal').textContent=d.audio_floor.toFixed(2);
    }
    if(document.activeElement!==document.getElementById('ceilSlider')&&d.audio_ceil!==undefined){
      document.getElementById('ceilSlider').value=Math.round(d.audio_ceil*100);
      document.getElementById('ceilVal').textContent=d.audio_ceil.toFixed(2);
    }
  }catch(e){document.getElementById('conn').className='conn';}
}
poll(); setInterval(poll,3000);
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
        self._audio_floor = 0.01
        self._audio_ceil  = 0.18

    # ── UDP helper ────────────────────────────────────────────────────────────
    def _send_godot(self, data: dict) -> None:
        """Fire-and-forget UDP command to Godot."""
        payload = json.dumps(data).encode()
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.sendto(payload, (self._godot_host, self._godot_port))

    # ── Page builder ──────────────────────────────────────────────────────────
    def _build_main_page(self) -> str:
        scene_btns = "\n".join(
            f'<button class="sb" data-scene="{s}" ontouchstart="" onclick="loadScene({json.dumps(s)})">{s}</button>'
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
            SESSION_COOKIE_SAMESITE='Lax',
            SESSION_COOKIE_SECURE=False,
            SESSION_COOKIE_HTTPONLY=True
        )

        pin_cfg = str(self._cfg.get("pin", "1234"))
        state   = self._state
        remote  = self

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
            pin  = str(data.get("pin", ""))
            # Use compare_digest to guard against timing attacks
            ok = secrets.compare_digest(pin, pin_cfg)
            if ok:
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
            first = data.get("first_name", "").strip()
            last = data.get("last_name", "").strip()
            if not first or not last:
                return jsonify({"ok": False, "error": "Name required"}), 400
            
            profiles_data = _load_profiles()
            new_id = secrets.token_hex(4)
            profiles_data["profiles"].append({
                "id": new_id,
                "first_name": first,
                "last_name": last,
                "created_at": time.time()
            })
            _save_profiles(profiles_data)
            return jsonify({"ok": True, "id": new_id})

        @app.post("/set_player")
        def set_player():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            data = request.get_json(silent=True) or {}
            pid = data.get("id")
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
            name = request.get_json(silent=True, force=True).get("scene", "")
            if name not in SCENE_SCRIPTS:
                return jsonify({"ok": False, "error": "unknown scene"}), 400
            state.set_scene_name(name)
            remote._send_godot({
                "type": "command",
                "cmd":  "load_scene",
                "scene": name,
                "script": SCENE_SCRIPTS[name],
            })
            return jsonify({"ok": True})

        @app.post("/tracker")
        def set_tracker():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            idx = int(request.get_json(silent=True, force=True).get("tracker_idx", 0))
            idx = max(0, min(idx, len(TRACKER_NAMES) - 1))
            state.request_tracker(idx)
            return jsonify({"ok": True})

        @app.post("/audio")
        def set_audio():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            data = request.get_json(silent=True, force=True) or {}
            fl   = float(data.get("floor", remote._audio_floor))
            cl   = float(data.get("ceil",  remote._audio_ceil))
            fl   = max(0.0, min(fl, 1.0))
            cl   = max(0.0, min(cl, 1.0))
            remote._audio_floor = fl
            remote._audio_ceil  = cl
            remote._send_godot({"type": "command", "cmd": "set_audio",
                                 "floor": fl, "ceiling": cl})
            return jsonify({"ok": True})

        @app.post("/clear_cursors")
        def clear_cursors():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            remote._send_godot({"type": "command", "cmd": "clear_cursors"})
            return jsonify({"ok": True})

        # ── Status ────────────────────────────────────────────────────────────
        @app.get("/status")
        def get_status():
            if not _authed():
                return jsonify({"ok": False, "error": "unauthorized"}), 401
            st = state.get_status()
            st["audio_floor"] = remote._audio_floor
            st["audio_ceil"]  = remote._audio_ceil
            return jsonify(st)

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
        except Exception as e:
            print(f"[WebRemote] QR generation skipped: {e}")

    # ── Public API ────────────────────────────────────────────────────────────
    def start(self) -> None:
        """Start Flask in a background daemon thread."""
        app = self._create_app()
        url = self.get_url()
        self._generate_qr(url)
        print(f"[WebRemote] QR saved to visual_layer/assets/remote_qr.png")

        def _run():
            import logging
            log = logging.getLogger("werkzeug")
            log.setLevel(logging.ERROR)   # suppress per-request output
            app.run(host="0.0.0.0", port=self._port, threaded=True, use_reloader=False)

        t = threading.Thread(target=_run, name="WebRemote", daemon=True)
        t.start()

    def get_url(self) -> str:
        return f"http://{_get_local_ip()}:{self._port}"
