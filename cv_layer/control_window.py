"""
control_window.py  —  Unified Tkinter control panel + camera preview.

Replaces two OpenCV windows (camera feed + trackbar settings) with a single
Tk window that shows:
  • Live camera preview  (one-click hide to cut render overhead entirely)
  • Tracker dropdown  + tracker-specific sliders (rebuilt on switch)
  • Resolution presets dropdown  (6 common sizes)
  • Global settings: camera idx, smoothing mode, EMA alpha, image adjustments

Main-loop integration (in main.py)::

    ui = ControlWindow()
    ui.rebuild_for_tracker(tracker)
    ui.set_click_callback(fn)   # fn(frame_x, frame_y) for calibration

    while ui.is_open() and cap.isOpened():
        ok, frame = cap.read()
        ...
        ui.update_preview(display_frame)   # no-op when preview hidden
        keys = ui.tick()                   # drives Tk events; returns key list
        if "q" in keys or "esc" in keys:
            break

Requires Pillow (pillow) for embedding frames.  Falls back gracefully if
Pillow is absent (preview disabled, everything else still works).
"""

import tkinter as tk
import cv2
import json
from pathlib import Path

try:
    from PIL import Image, ImageTk
    _PIL_OK = True
except ImportError:
    _PIL_OK = False

# ---------------------------------------------------------------------------
# Constants shared with main.py / camera_ui.py
# ---------------------------------------------------------------------------
TRACKER_NAMES = ["Hands", "Blob", "Motion", "Color", "Edge", "Object"]
SMOOTH_LABELS = ["None", "EMA", "Kalman"]

_SETTINGS_PATH = Path(__file__).parent.parent / "last_settings.json"

# (display_label, cap_width, cap_height)
RESOLUTIONS = [
    ("160 × 120",   160,  120),
    ("320 × 240",   320,  240),
    ("640 × 480",   640,  480),
    ("800 × 600",   800,  600),
    ("1280 × 720", 1280,  720),
    ("1920 × 1080",1920, 1080),
]
_DEFAULT_RES = "640 × 480"

# ---------------------------------------------------------------------------
# Colour palette (dark theme)
# ---------------------------------------------------------------------------
_DARK  = "#1e1e1e"
_PANEL = "#252525"
_SEP   = "#303030"
_TXT   = "#cccccc"
_TXT2  = "#777777"
_ACC   = "#4db8ff"   # section headings
_ACC2  = "#ffcc55"   # tracker-specific slider labels
_BTN   = "#2d2d2d"
_BTN_H = "#3a3a3a"


def _load_settings(path=_SETTINGS_PATH):
    defaults = {
        "camera_idx": 0, "tracker_idx": 0, "smoothing_mode": 1,
        "ema_alpha": 35, "resolution": _DEFAULT_RES, "brightness": 50,
        "contrast": 50, "flip_h": False, "show_mask": False,
        "target_fps": 30, "pointers_visible": True,
    }
    if path.exists():
        try:
            with open(path, encoding="utf-8") as settings_file:
                saved = json.load(settings_file)
            if isinstance(saved, dict):
                defaults.update(saved)
            else:
                print("[ControlWindow] Settings must be a JSON object; using defaults")
        except (OSError, ValueError, TypeError) as exc:
            print(f"[ControlWindow] Settings could not be loaded: {exc}")

    def bounded_int(key, default, low, high):
        try:
            return max(low, min(high, int(defaults.get(key, default))))
        except (TypeError, ValueError):
            print(f"[ControlWindow] Invalid {key} setting; using {default}")
            return default

    def safe_bool(key, default):
        value = defaults.get(key, default)
        if isinstance(value, bool):
            return value
        if value in (0, 1):
            return bool(value)
        if isinstance(value, str) and value.lower() in ("true", "false"):
            return value.lower() == "true"
        print(f"[ControlWindow] Invalid {key} setting; using {default}")
        return default

    defaults["camera_idx"] = bounded_int("camera_idx", 0, 0, 9)
    defaults["tracker_idx"] = bounded_int("tracker_idx", 0, 0, len(TRACKER_NAMES) - 1)
    defaults["smoothing_mode"] = bounded_int("smoothing_mode", 1, 0, len(SMOOTH_LABELS) - 1)
    defaults["ema_alpha"] = bounded_int("ema_alpha", 35, 1, 95)
    defaults["target_fps"] = bounded_int("target_fps", 30, 1, 60)
    defaults["brightness"] = bounded_int("brightness", 50, 0, 100)
    defaults["contrast"] = bounded_int("contrast", 50, 0, 100)
    for key in ("flip_h", "show_mask", "pointers_visible"):
        defaults[key] = safe_bool(key, key == "pointers_visible")
    if defaults.get("resolution") not in [resolution[0] for resolution in RESOLUTIONS]:
        print("[ControlWindow] Invalid resolution setting; using default")
        defaults["resolution"] = _DEFAULT_RES
    return defaults


class ControlWindow:
    """
    Unified camera preview + settings panel in a single Tkinter window.

    Public API
    ----------
    rebuild_for_tracker(tracker)    — rebuild tracker-specific slider section
    set_click_callback(fn)          — fn(frame_x, frame_y) on preview click
    update_preview(frame_bgr)       — push a BGR ndarray to the preview label
    tick() -> list[str]             — drive Tk event loop; return key chars
    is_open() -> bool               — False after window is closed
    read() -> dict                  — return all current settings
    """

    # ------------------------------------------------------------------
    def __init__(self):
        self._root = tk.Tk()
        self._root.title("LightTable CV")
        self._root.configure(bg=_DARK)
        self._root.resizable(False, False)
        self._root.protocol("WM_DELETE_WINDOW", self._on_close)

        self._alive          = True
        self._preview_on     = True
        self._photo          = None        # keep ImageTk ref alive (GC guard)
        self._preview_scale  = 1.0         # last scale used → click coord mapping
        self._pending_keys: list = []

        defaults = _load_settings()

        # ── Global Tk variables ─────────────────────────────────────────────
        self._camera_var    = tk.IntVar(value=defaults["camera_idx"])
        self._tracker_var   = tk.StringVar(value=TRACKER_NAMES[defaults["tracker_idx"]])
        self._smooth_var    = tk.StringVar(value=SMOOTH_LABELS[defaults["smoothing_mode"]])
        self._ema_var       = tk.IntVar(value=defaults["ema_alpha"])
        self._fliph_var     = tk.BooleanVar(value=defaults["flip_h"])
        self._showmask_var  = tk.BooleanVar(value=defaults["show_mask"])
        self._bright_var    = tk.IntVar(value=defaults["brightness"])
        self._contrast_var  = tk.IntVar(value=defaults["contrast"])
        self._res_var       = tk.StringVar(value=defaults["resolution"])
        self._fps_var       = tk.IntVar(value=defaults["target_fps"])
        self._pointers_var  = tk.BooleanVar(value=defaults["pointers_visible"])

        # Tracker-specific slider vars: {name: IntVar}
        self._tracker_vars: dict   = {}
        self._tracker_frame: tk.Frame | None = None

        # External callback
        self._click_callback = None
        self._calibration_action_callback = None
        self._last_saved_settings = None

        self._build_ui()
        self._root.bind_all("<KeyPress>", self._on_keypress)

    # ------------------------------------------------------------------
    # Window lifecycle
    # ------------------------------------------------------------------
    def _on_close(self):
        self._alive = False
        try:
            self._root.destroy()
        except tk.TclError:
            pass

    # ------------------------------------------------------------------
    # Key handling
    # ------------------------------------------------------------------
    def _on_keypress(self, event: tk.Event):
        char = event.char.lower() if event.char else ""
        if event.keysym == "Escape":
            char = "esc"
        if char:
            self._pending_keys.append(char)

    # ------------------------------------------------------------------
    # UI construction
    # ------------------------------------------------------------------
    def _build_ui(self):
        root = self._root

        # ── Left column : camera preview ──────────────────────────────
        left = tk.Frame(root, bg=_DARK)
        left.grid(row=0, column=0, padx=8, pady=8, sticky="n")

        self._preview_label = tk.Label(
            left, bg="#111111",
            text="No Frame", fg="#333333",
            font=("Helvetica", 14),
        )
        self._preview_label.pack()
        self._preview_label.bind("<Button-1>", self._on_preview_click)

        self._preview_btn = tk.Button(
            left,
            text="⏸  Hide Preview",
            bg=_BTN, fg=_TXT,
            activebackground=_BTN_H, activeforeground="white",
            font=("Helvetica", 9), relief="flat", pady=5,
            command=self._toggle_preview,
        )
        self._preview_btn.pack(fill="x", pady=(4, 0))

        # Pillow warning if missing
        if not _PIL_OK:
            tk.Label(
                left,
                text="Install Pillow to enable preview:\n  pip install pillow",
                bg=_DARK, fg="#cc4444",
                font=("Helvetica", 9),
            ).pack(pady=(4, 0))

        # ── Right column : settings ────────────────────────────────────
        right = tk.Frame(root, bg=_DARK, width=290)
        right.grid(row=0, column=1, padx=(0, 8), pady=8, sticky="n")
        right.grid_propagate(False)

        # — Tracker selector (with prominent name) ———————————————————
        self._add_section_label(right, "TRACKER")
        om_tracker = tk.OptionMenu(right, self._tracker_var, *TRACKER_NAMES)
        self._style_menu(om_tracker)
        om_tracker.pack(fill="x", pady=(0, 4))

        # Tracker-specific sliders (populated by rebuild_for_tracker)
        self._tracker_frame = tk.Frame(right, bg=_DARK)
        self._tracker_frame.pack(fill="x")

        self._sep(right)

        # — Resolution ————————————————————————————————————————————————
        self._add_section_label(right, "RESOLUTION")
        res_labels = [r[0] for r in RESOLUTIONS]
        om_res = tk.OptionMenu(right, self._res_var, *res_labels)
        self._style_menu(om_res)
        om_res.pack(fill="x", pady=(0, 6))
        self._add_slider(right, "Target FPS", self._fps_var, 1, 60)

        # — Camera index ——————————————————————————————————————————————
        self._add_section_label(right, "CAMERA")
        self._add_slider(right, "Camera Idx", self._camera_var, 0, 9)

        self._sep(right)

        # — Smoothing —————————————————————————————————————————————————
        self._add_section_label(right, "SMOOTHING")
        om_smooth = tk.OptionMenu(right, self._smooth_var, *SMOOTH_LABELS)
        self._style_menu(om_smooth)
        om_smooth.pack(fill="x", pady=(0, 4))
        self._add_slider(right, "EMA Respons", self._ema_var, 1, 95)

        self._sep(right)

        # — Image adjustments —————————————————————————————————————————
        self._add_section_label(right, "IMAGE")
        self._add_slider(right, "Brightness", self._bright_var,   0, 100)
        self._add_slider(right, "Contrast",   self._contrast_var, 0, 100)
        toggle_row = tk.Frame(right, bg=_DARK)
        toggle_row.pack(fill="x", pady=(4, 0))
        for text, var in (("Flip H", self._fliph_var), ("Show Mask", self._showmask_var), ("Pointers", self._pointers_var)):
            tk.Checkbutton(
                toggle_row, text=text, variable=var,
                bg=_DARK, fg=_TXT2, selectcolor="#333",
                activebackground=_DARK, font=("Helvetica", 9),
            ).pack(side="left", padx=(0, 10))

        self._sep(right)
        self._add_section_label(right, "CALIBRATION")
        self._calibration_status = tk.Label(
            right, text="Uncalibrated", bg=_DARK, fg=_TXT,
            font=("Helvetica", 8), justify="left", wraplength=275, anchor="w",
        )
        self._calibration_status.pack(fill="x", pady=(2, 4))
        self._calibration_config = tk.Label(
            right, text="Camera: waiting", bg=_DARK, fg=_TXT2,
            font=("Helvetica", 8), justify="left", anchor="w",
        )
        self._calibration_config.pack(fill="x", pady=(0, 4))
        calibration_buttons = tk.Frame(right, bg=_DARK)
        calibration_buttons.pack(fill="x")
        for label, action in (
            ("Start", "start"), ("Undo", "undo"), ("Reset", "reset"),
            ("Cancel", "cancel"), ("Save", "save"), ("Load", "load"),
        ):
            tk.Button(
                calibration_buttons, text=label, bg=_BTN, fg=_TXT,
                activebackground=_BTN_H, activeforeground="white",
                font=("Helvetica", 8), relief="flat", padx=3,
                command=lambda selected=action: self._calibration_action(selected),
            ).pack(side="left", expand=True, fill="x", padx=1)

        self._diagnostics_label = tk.Label(
            right, text="Camera: waiting", bg=_DARK, fg=_TXT2,
            font=("Helvetica", 8), justify="left", wraplength=275, anchor="w",
        )
        self._diagnostics_label.pack(fill="x", pady=(5, 0))

    # ------------------------------------------------------------------
    # UI helpers
    # ------------------------------------------------------------------
    def _sep(self, parent):
        tk.Frame(parent, bg=_SEP, height=1).pack(fill="x", pady=8)

    def _add_section_label(self, parent, text):
        tk.Label(
            parent, text=text,
            bg=_DARK, fg=_ACC,
            font=("Helvetica", 8, "bold"), anchor="w",
        ).pack(fill="x", pady=(4, 0))

    def _add_slider(self, parent, name, var, lo, hi, accent=False):
        row = tk.Frame(parent, bg=_DARK)
        row.pack(fill="x", pady=1)
        fg_col = _ACC2 if accent else _TXT2
        tk.Label(
            row, text=name, width=11, anchor="w",
            bg=_DARK, fg=fg_col, font=("Helvetica", 9),
        ).pack(side="left")
        tk.Label(
            row, textvariable=var, width=4, anchor="e",
            bg=_DARK, fg=_TXT, font=("Helvetica", 9),
        ).pack(side="right")
        tk.Scale(
            row, variable=var, from_=lo, to=hi,
            orient="horizontal",
            bg=_DARK, fg=_TXT, troughcolor=_SEP,
            highlightthickness=0, sliderlength=12, showvalue=False,
        ).pack(side="left", fill="x", expand=True, padx=(4, 2))

    @staticmethod
    def _style_menu(widget):
        widget.config(
            bg=_BTN, fg=_TXT,
            activebackground=_BTN_H, activeforeground="white",
            font=("Helvetica", 10), relief="flat",
            highlightthickness=0, anchor="w",
        )
        widget["menu"].config(bg=_BTN, fg=_TXT, font=("Helvetica", 10))

    # ------------------------------------------------------------------
    # Tracker-specific sliders
    # ------------------------------------------------------------------
    def rebuild_for_tracker(self, tracker):
        """Destroy and rebuild the tracker-specific slider section."""
        for w in self._tracker_frame.winfo_children():
            w.destroy()
        self._tracker_vars.clear()

        # Update tracker dropdown to match (if switched programmatically)
        if hasattr(tracker, "name"):
            short = tracker.name.split()[0] if " " in tracker.name else tracker.name
            # Find matching entry
            for tn in TRACKER_NAMES:
                if short.lower() in tn.lower() or tn.lower() in short.lower():
                    self._tracker_var.set(tn)
                    break

        specs = tracker.get_trackbar_settings()
        if not specs:
            return

        self._add_section_label(self._tracker_frame, tracker.name.upper())

        for s in specs:
            var = tk.IntVar(value=s["default"])
            # Bind: every slider move → tracker.on_trackbar(name, value)
            var.trace_add(
                "write",
                lambda *_, n=s["name"], v=var, t=tracker: t.on_trackbar(n, v.get()),
            )
            self._tracker_vars[s["name"]] = var
            self._add_slider(self._tracker_frame, s["name"], var, 0, s["max"], accent=True)

    # ------------------------------------------------------------------
    # Camera preview
    # ------------------------------------------------------------------
    def _toggle_preview(self):
        self._preview_on = not self._preview_on
        if self._preview_on:
            self._preview_btn.config(text="⏸  Hide Preview")
        else:
            self._preview_label.config(
                image="",
                text="Preview Off\n(tracking active)",
                width=40, height=10,
                font=("Helvetica", 14),
            )
            self._preview_btn.config(text="▶  Show Preview")

    def update_preview(self, frame_bgr):
        """
        Push a BGR frame to the preview panel.
        Completely skipped (zero overhead) when preview is hidden or Pillow absent.
        """
        if not self._preview_on or not _PIL_OK:
            return
        h, w = frame_bgr.shape[:2]
        # Scale down to fit 640 × 480 max; never scale up
        scale = min(640 / w, 480 / h, 1.0)
        self._preview_scale = scale
        if scale < 1.0:
            frame_bgr = cv2.resize(
                frame_bgr, (int(w * scale), int(h * scale)),
                interpolation=cv2.INTER_LINEAR,
            )
        rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
        img = Image.fromarray(rgb)
        self._photo = ImageTk.PhotoImage(img)
        self._preview_label.config(
            image=self._photo, text="",
            width=img.width, height=img.height,
        )

    # ------------------------------------------------------------------
    # Calibration click
    # ------------------------------------------------------------------
    def set_click_callback(self, fn):
        """Register fn(frame_x: int, frame_y: int) for calibration clicks."""
        self._click_callback = fn

    def set_calibration_action_callback(self, fn):
        self._calibration_action_callback = fn

    def _calibration_action(self, action):
        if self._calibration_action_callback:
            self._calibration_action_callback(action)

    def update_calibration_status(self, state, message, camera_idx=None, resolution=None):
        self._calibration_status.config(text=f"{state.capitalize()}: {message}")
        if camera_idx is not None and resolution is not None:
            self._calibration_config.config(
                text=f"Camera {camera_idx} • {resolution[0]}×{resolution[1]}"
            )

    def update_diagnostics(self, status):
        self._diagnostics_label.config(
            text=(
                f"Camera: {status.get('camera', 'unavailable')}  "
                f"Capture: {status.get('capture_fps', 0):.1f} fps\n"
                f"Processing: {status.get('processing_fps', 0):.1f} fps  "
                f"Detections: {status.get('detections', 0)}\n"
                f"Mode: {status.get('tracker', 'Unknown')}  "
                f"UDP: {status.get('udp', 'waiting')}"
            )
        )

    def _on_preview_click(self, event: tk.Event):
        if not self._preview_on or not self._click_callback:
            return
        # Map display coordinates → original frame coordinates
        fx = int(event.x / max(self._preview_scale, 1e-6))
        fy = int(event.y / max(self._preview_scale, 1e-6))
        self._click_callback(fx, fy)

    # ------------------------------------------------------------------
    # Main-loop integration
    # ------------------------------------------------------------------
    def tick(self) -> list:
        """
        Drive the Tkinter event loop for one iteration.
        Returns the list of key chars pressed since the last tick().
        Call this once per camera frame in your main loop.
        """
        try:
            self._root.update()
        except tk.TclError:
            self._alive = False
        keys = self._pending_keys[:]
        self._pending_keys.clear()
        return keys

    def is_open(self) -> bool:
        """False once the user closes the window."""
        return self._alive

    # ------------------------------------------------------------------
    # Settings read
    # ------------------------------------------------------------------
    def read(self) -> dict:
        """
        Return all current settings as a dict.
        Matches the keys of the old CameraUI.read() and adds "Resolution".
        """
        sm = self._smooth_var.get()
        smooth_idx = SMOOTH_LABELS.index(sm) if sm in SMOOTH_LABELS else 1

        tr = self._tracker_var.get()
        tracker_idx = TRACKER_NAMES.index(tr) if tr in TRACKER_NAMES else 0

        rn = self._res_var.get()
        res_entry = next((r for r in RESOLUTIONS if r[0] == rn), RESOLUTIONS[2])

        s = {
            "Camera Idx":  self._camera_var.get(),
            "Tracker":     tracker_idx,
            "Smoothing":   smooth_idx,
            "EMA Respons": self._ema_var.get(),
            "Flip H":      int(self._fliph_var.get()),
            "Show Mask":   int(self._showmask_var.get()),
            "Brightness":  self._bright_var.get(),
            "Contrast":    self._contrast_var.get(),
            "Resolution":  (res_entry[1], res_entry[2]),
            "Target FPS":  max(1, self._fps_var.get()),
            "Pointers":    self._pointers_var.get(),
            "_res_label":  rn
        }
        self._save_settings(s)
        return s

    def _save_settings(self, s: dict):
        save_data = {
            "camera_idx":       s["Camera Idx"],
            "tracker_idx":      s["Tracker"],
            "smoothing_mode":   s["Smoothing"],
            "ema_alpha":        s["EMA Respons"],
            "resolution":       s["_res_label"],
            "brightness":       s["Brightness"],
            "contrast":         s["Contrast"],
            "flip_h":           bool(s["Flip H"]),
            "show_mask":        bool(s["Show Mask"]),
            "target_fps":       s["Target FPS"],
            "pointers_visible": s["Pointers"],
        }
        if save_data == self._last_saved_settings:
            return
        try:
            with open(_SETTINGS_PATH, "w") as f:
                json.dump(save_data, f, indent=2)
            self._last_saved_settings = save_data
        except OSError as exc:
            print(f"[ControlWindow] Settings could not be saved: {exc}")
