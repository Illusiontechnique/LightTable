import cv2
import mediapipe as mp
from .base_tracker import BaseTracker


# Palm-base landmarks used for palm-center calculation
_PALM_LM = [0, 5, 9, 13, 17]


class HandTracker(BaseTracker):
    """
    MediaPipe Hands — up to N hands.
    Auto Gesture mode (trackbar):
      0 = always report index fingertip (landmark 8)
      1 = pointing gesture → index tip;  open palm / any other pose → palm centre
    Pointing heuristic: index tip (8) above its PIP (6) AND middle tip (12) below its PIP (10).
    """

    name = "MediaPipe Hands"

    def __init__(self):
        self._detect_conf   = 50   # trackbar 1-100
        self._track_conf    = 50
        self._max_hands     = 4
        self._draw_skel     = 1
        self._auto_gesture  = 1    # 0=always index tip, 1=gesture-aware
        self.mp_hands = mp.solutions.hands
        self.mp_draw  = mp.solutions.drawing_utils
        self._last_results = None
        self._init_hands()

    # ------------------------------------------------------------------
    def _init_hands(self):
        if hasattr(self, "hands"):
            self.hands.close()
        self.hands = self.mp_hands.Hands(
            static_image_mode=False,
            max_num_hands=self._max_hands,
            min_detection_confidence=self._detect_conf / 100.0,
            min_tracking_confidence=self._track_conf  / 100.0,
        )

    # ------------------------------------------------------------------
    @staticmethod
    def _is_pointing(lm) -> bool:
        """True when index finger is extended and middle finger is curled."""
        idx_tip = lm.landmark[8]
        idx_pip = lm.landmark[6]
        mid_tip = lm.landmark[12]
        mid_pip = lm.landmark[10]
        # In image-space Y increases downward, so tip.y < pip.y  →  tip is higher
        return (idx_tip.y < idx_pip.y) and (mid_tip.y > mid_pip.y)

    @staticmethod
    def _palm_center(lm, w: int, h: int):
        """Average position of wrist + 4 MCP joints in pixel coords."""
        cx = sum(lm.landmark[i].x for i in _PALM_LM) / len(_PALM_LM)
        cy = sum(lm.landmark[i].y for i in _PALM_LM) / len(_PALM_LM)
        return cx * w, cy * h

    # ------------------------------------------------------------------
    def process(self, frame) -> list:
        h, w = frame.shape[:2]
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        self._last_results = self.hands.process(rgb)
        detections = []
        if self._last_results.multi_hand_landmarks:
            for i, lm in enumerate(self._last_results.multi_hand_landmarks):
                if self._auto_gesture and not self._is_pointing(lm):
                    # Open palm / non-pointing → report palm centre
                    px, py = self._palm_center(lm, w, h)
                    detections.append({"id": i, "x": px, "y": py})
                else:
                    # Pointing (or gesture detection off) → index fingertip
                    tip = lm.landmark[8]
                    detections.append({"id": i, "x": tip.x * w, "y": tip.y * h})
        return detections

    def draw_debug(self, frame, detections):
        if self._draw_skel and self._last_results and self._last_results.multi_hand_landmarks:
            for lm in self._last_results.multi_hand_landmarks:
                self.mp_draw.draw_landmarks(frame, lm, self.mp_hands.HAND_CONNECTIONS)
        return frame

    # ------------------------------------------------------------------
    def get_trackbar_settings(self):
        return [
            {"name": "Detect Conf",  "max": 100, "default": 50},
            {"name": "Track Conf",   "max": 100, "default": 50},
            {"name": "Max Hands",    "max": 6,   "default": 4},
            {"name": "Draw Skel",    "max": 1,   "default": 1},
            {"name": "Auto Gesture", "max": 1,   "default": 1},
        ]

    def on_trackbar(self, name, value):
        if   name == "Detect Conf":  self._detect_conf  = max(1, value); self._init_hands()
        elif name == "Track Conf":   self._track_conf   = max(1, value); self._init_hands()
        elif name == "Max Hands":    self._max_hands    = max(1, value); self._init_hands()
        elif name == "Draw Skel":    self._draw_skel    = value
        elif name == "Auto Gesture": self._auto_gesture = value

    def reset(self):
        self._last_results = None
        self._init_hands()
