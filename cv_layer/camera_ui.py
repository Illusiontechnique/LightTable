import cv2
import numpy as np

# -----------------------------------------------------------------------
# Tracker names must match TRACKER_CLASSES order in main.py
# -----------------------------------------------------------------------
TRACKER_NAMES = ["Hands", "Blob", "Motion", "Color", "Edge", "Object"]
SMOOTH_LABELS = ["None", "EMA", "Kalman"]

# (bar_name, max_value, default_value)
# These are the fixed global bars always present regardless of active tracker.
_FIXED_BARS = [
    ("Camera Idx",  9,   0),
    ("Tracker",     5,   0),   # index into TRACKER_NAMES
    ("Smoothing",   2,   1),   # 0=none 1=EMA 2=Kalman
    ("EMA Respons", 95,  35),  # EMA alpha ×100 (higher = more responsive)
    ("Flip H",      1,   0),
    ("Show Mask",   1,   0),   # show binary mask for supported trackers
    ("Brightness",  100, 50),  # 50 = neutral
    ("Contrast",    100, 50),  # 50 = neutral (alpha=1.0)
]

_WIN = "LightTable Settings"


class CameraUI:
    """
    Manages a persistent OpenCV settings window with:
      • Fixed global trackbars (camera, tracker, smoothing, image adjustments)
      • Tracker-specific trackbars that are rebuilt when the tracker changes

    Usage:
        ui = CameraUI()
        ui.create_window(tracker)        # once at startup
        settings = ui.read()             # every frame
        ui.rebuild_for_tracker(tracker)  # when tracker switches
    """

    def __init__(self):
        # Initialise cache from defaults so read() works before window exists
        self._cached = {name: default for name, _, default in _FIXED_BARS}
        self._alive  = False

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------
    @staticmethod
    def _blank():
        img = np.zeros((55, 520, 3), dtype=np.uint8)
        cv2.putText(
            img, "LightTable CV  |  Settings",
            (12, 36), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (180, 180, 180), 1,
        )
        return img

    def _build(self, tracker):
        cv2.namedWindow(_WIN, cv2.WINDOW_NORMAL)
        cv2.imshow(_WIN, self._blank())
        cv2.waitKey(1)

        for name, max_val, default in _FIXED_BARS:
            val = self._cached.get(name, default)
            cv2.createTrackbar(name, _WIN, int(val), max_val, lambda v: None)

        for s in tracker.get_trackbar_settings():
            cv2.createTrackbar(
                s["name"], _WIN, s["default"], s["max"],
                lambda v, n=s["name"], t=tracker: t.on_trackbar(n, v),
            )

        self._alive = True

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------
    def create_window(self, tracker):
        """Call once at startup."""
        self._build(tracker)

    def rebuild_for_tracker(self, tracker):
        """
        Destroy and recreate the settings window with new tracker-specific bars.
        Fixed bars are restored to their cached values.
        """
        if self._alive:
            try:
                self._cached = self.read()
            except Exception:
                pass
        self._alive = False
        cv2.destroyWindow(_WIN)
        cv2.waitKey(1)
        self._build(tracker)

    def read(self) -> dict:
        """
        Return current settings as a dict keyed by bar name.
        Falls back to cached values if the window is being rebuilt.
        """
        if not self._alive:
            return dict(self._cached)
        try:
            result = {name: cv2.getTrackbarPos(name, _WIN) for name, _, _ in _FIXED_BARS}
            self._cached = result
            return result
        except cv2.error:
            return dict(self._cached)
