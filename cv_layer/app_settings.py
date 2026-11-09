"""Authoritative, Tk-independent operator settings."""

import json
import os
import tempfile
import time
from pathlib import Path

TRACKER_NAMES = ["Hands", "Blob", "Motion", "Color", "Edge", "Object"]
SMOOTH_LABELS = ["None", "EMA", "Kalman"]
RESOLUTIONS = [
    ("160 × 120", 160, 120), ("320 × 240", 320, 240),
    ("640 × 480", 640, 480), ("800 × 600", 800, 600),
    ("1280 × 720", 1280, 720), ("1920 × 1080", 1920, 1080),
]
SETTINGS_PATH = Path(__file__).parent.parent / "last_settings.json"

DEFAULTS = {
    "camera_idx": 0, "tracker_idx": 0, "smoothing_mode": 1,
    "ema_alpha": 35, "resolution": "640 × 480", "brightness": 50,
    "contrast": 50, "flip_h": False, "show_mask": False, "target_fps": 30,
    "pointers_visible": True, "motion_enabled": True, "motion_threshold": 25,
    "motion_min_percent": 1, "motion_delay_ms": 50, "desktop": False,
}

RANGES = {
    "camera": ("camera_idx", 0, 9), "brightness": ("brightness", 0, 100),
    "contrast": ("contrast", 0, 100), "ema": ("ema_alpha", 1, 95),
    "fps": ("target_fps", 1, 60), "motion_threshold": ("motion_threshold", 1, 100),
    "motion_min": ("motion_min_percent", 0, 20), "motion_delay": ("motion_delay_ms", 50, 1000),
}
BOOLS = {"flip": "flip_h", "motion": "motion_enabled", "pointers": "pointers_visible",
         "show_mask": "show_mask"}


def load_settings(path=SETTINGS_PATH):
    values = dict(DEFAULTS)
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                raise ValueError("settings must be an object")
            values.update(data)
        except (OSError, ValueError, TypeError) as exc:
            print(f"[Settings] Could not load settings: {exc}")
    bounds = {key: (lo, hi) for key, lo, hi in RANGES.values()}
    bounds.update({"tracker_idx": (0, len(TRACKER_NAMES) - 1),
                   "smoothing_mode": (0, len(SMOOTH_LABELS) - 1)})
    for key, (low, high) in bounds.items():
        try:
            values[key] = max(low, min(high, int(values[key])))
        except (TypeError, ValueError, OverflowError):
            print(f"[Settings] Invalid {key}; using default")
            values[key] = DEFAULTS[key]
    for key in (*BOOLS.values(), "desktop"):
        value = values[key]
        if isinstance(value, bool):
            continue
        if value in (0, 1):
            values[key] = bool(value)
        elif isinstance(value, str) and value.lower() in ("true", "false"):
            values[key] = value.lower() == "true"
        else:
            print(f"[Settings] Invalid {key}; using default")
            values[key] = DEFAULTS[key]
    if values["resolution"] not in [r[0] for r in RESOLUTIONS]:
        print("[Settings] Invalid resolution; using default")
        values["resolution"] = DEFAULTS["resolution"]
    return values


class AppSettings:
    def __init__(self, path=SETTINGS_PATH):
        self.path = Path(path)
        self.values = load_settings(self.path)
        self._persisted = dict(self.values)
        self._changed_at = None
        self.tracker = None
        self.tracker_values = {}
        self.preview_mode = "Camera"

    def rebuild_for_tracker(self, tracker):
        self.tracker = tracker
        all_saved = self.values.get("tracker_parameters", {})
        saved = all_saved.get(tracker.name, {}) if isinstance(all_saved, dict) else {}
        if not isinstance(saved, dict):
            saved = {}
        self.tracker_values = {}
        for spec in tracker.get_trackbar_settings():
            value = saved.get(spec["name"], spec["default"])
            if type(value) is not int or not 0 <= value <= spec["max"]:
                print(f"[Settings] Invalid {tracker.name} parameter {spec['name']}; using default")
                value = spec["default"]
            self.tracker_values[spec["name"]] = value
            if value != spec["default"]:
                tracker.on_trackbar(spec["name"], value)

    def operator_settings(self, tracker):
        settings = {name: {"value": self.values[key], "min": lo, "max": hi}
                    for name, (key, lo, hi) in RANGES.items()}
        settings.update({name: {"value": self.values[key], "type": "boolean"}
                         for name, key in BOOLS.items()})
        settings["resolution"] = {"value": self.values["resolution"], "options": [r[0] for r in RESOLUTIONS]}
        settings["smoothing"] = {"value": SMOOTH_LABELS[self.values["smoothing_mode"]], "options": SMOOTH_LABELS}
        settings["tracker"] = {"value": TRACKER_NAMES[self.values["tracker_idx"]], "options": TRACKER_NAMES}
        settings["desktop_next_start"] = {"value": self.values["desktop"], "type": "boolean"}
        tracker_settings = {s["name"]: {"value": self.tracker_values[s["name"]], "min": 0, "max": s["max"]}
                            for s in tracker.get_trackbar_settings()}
        return {"settings": settings, "tracker_settings": tracker_settings, "tracker_name": tracker.name}

    def apply_operator_settings(self, values, tracker_values):
        before = dict(self.values)
        for name, value in values.items():
            if name in RANGES:
                self.values[RANGES[name][0]] = value
            elif name in BOOLS:
                self.values[BOOLS[name]] = value
            elif name == "tracker":
                self.values["tracker_idx"] = TRACKER_NAMES.index(value)
            elif name == "smoothing":
                self.values["smoothing_mode"] = SMOOTH_LABELS.index(value)
            elif name == "resolution":
                self.values["resolution"] = value
            elif name == "desktop_next_start":
                self.values["desktop"] = value
            else:
                raise ValueError(f"Unknown setting: {name}")
        if self.values != before:
            self._changed_at = time.monotonic()
        for name, value in tracker_values.items():
            if name not in self.tracker_values:
                raise ValueError(f"Unknown tracker setting: {name}")
            if self.tracker_values[name] != value:
                self.tracker.on_trackbar(name, value)
                self.tracker_values[name] = value
                stored = self.values.get("tracker_parameters")
                if not isinstance(stored, dict):
                    stored = {}
                stored = dict(stored)
                stored[self.tracker.name] = dict(self.tracker_values)
                self.values["tracker_parameters"] = stored
                self._changed_at = time.monotonic()

    def read(self):
        v = self.values
        res = next(r for r in RESOLUTIONS if r[0] == v["resolution"])
        return {"Camera Idx": v["camera_idx"], "Tracker": v["tracker_idx"],
                "Smoothing": v["smoothing_mode"], "EMA Respons": v["ema_alpha"],
                "Flip H": v["flip_h"], "Show Mask": v["show_mask"],
                "Brightness": v["brightness"], "Contrast": v["contrast"],
                "Resolution": (res[1], res[2]), "Target FPS": v["target_fps"],
                "Pointers": v["pointers_visible"], "Frame Motion": v["motion_enabled"],
                "Motion Threshold": v["motion_threshold"], "Motion Min Percent": v["motion_min_percent"],
                "Motion Delay ms": v["motion_delay_ms"], "Preview Mode": self.preview_mode}

    def save(self, force=False):
        if self.values == self._persisted:
            return
        if not force and (self._changed_at is None or time.monotonic() - self._changed_at < 1.0):
            return
        temp = None
        try:
            fd, temp = tempfile.mkstemp(prefix=".lighttable-settings-", dir=str(self.path.parent))
            with os.fdopen(fd, "w", encoding="utf-8") as file:
                json.dump(self.values, file, indent=2)
            os.replace(temp, self.path)
        except OSError as exc:
            print(f"[Settings] Could not save settings: {exc}")
            if temp is not None and os.path.exists(temp):
                os.unlink(temp)
            return
        self._persisted = dict(self.values)
        self._changed_at = None
