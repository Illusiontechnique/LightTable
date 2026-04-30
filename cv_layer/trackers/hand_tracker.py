import cv2
import mediapipe as mp
from .base_tracker import BaseTracker


class HandTracker(BaseTracker):
    """MediaPipe Hands — tracks up to N hands, reports index fingertip (landmark 8)."""

    name = "MediaPipe Hands"

    def __init__(self):
        self._detect_conf = 50   # trackbar 1-100
        self._track_conf  = 50
        self._max_hands   = 4
        self._draw_skel   = 1
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
    def process(self, frame) -> list:
        h, w = frame.shape[:2]
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        self._last_results = self.hands.process(rgb)
        detections = []
        if self._last_results.multi_hand_landmarks:
            for i, lm in enumerate(self._last_results.multi_hand_landmarks):
                tip = lm.landmark[8]  # index fingertip
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
            {"name": "Detect Conf", "max": 100, "default": 50},
            {"name": "Track Conf",  "max": 100, "default": 50},
            {"name": "Max Hands",   "max": 6,   "default": 4},
            {"name": "Draw Skel",   "max": 1,   "default": 1},
        ]

    def on_trackbar(self, name, value):
        if   name == "Detect Conf": self._detect_conf = max(1, value); self._init_hands()
        elif name == "Track Conf":  self._track_conf  = max(1, value); self._init_hands()
        elif name == "Max Hands":   self._max_hands   = max(1, value); self._init_hands()
        elif name == "Draw Skel":   self._draw_skel   = value

    def reset(self):
        self._last_results = None
        self._init_hands()
