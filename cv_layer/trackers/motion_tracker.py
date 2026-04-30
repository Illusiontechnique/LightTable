import cv2
import numpy as np
from .base_tracker import BaseTracker


class MotionTracker(BaseTracker):
    """
    MOG2 Gaussian background subtraction — detects any object that moves relative
    to a learned background model.  Robust to gradual lighting changes.
    Good for detecting hands/objects on a mostly-static light table surface.
    """

    name = "Motion Detection"

    def __init__(self):
        self._history   = 200
        self._var_thresh = 16
        self._min_area  = 500
        self._blur      = 5
        self._dilate    = 3
        self._contours  = []
        self._mask      = None
        self._init_bg()

    # ------------------------------------------------------------------
    def _init_bg(self):
        self.bg_sub = cv2.createBackgroundSubtractorMOG2(
            history=self._history,
            varThreshold=self._var_thresh,
            detectShadows=False,
        )
        self._contours = []
        self._mask     = None

    # ------------------------------------------------------------------
    def process(self, frame) -> list:
        k       = self._blur * 2 + 1
        blurred = cv2.GaussianBlur(frame, (k, k), 0)
        mask    = self.bg_sub.apply(blurred)

        # Morphological closing to fill holes in moving regions
        dk     = self._dilate * 2 + 1
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (dk, dk))
        mask   = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
        self._mask = mask

        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        detections   = []
        self._contours = []
        for i, cnt in enumerate(contours):
            area = cv2.contourArea(cnt)
            if area < self._min_area:
                continue
            M = cv2.moments(cnt)
            if M["m00"] != 0:
                cx = M["m10"] / M["m00"]
                cy = M["m01"] / M["m00"]
                detections.append({"id": i, "x": cx, "y": cy, "area": area})
                self._contours.append(cnt)
        return detections

    def draw_debug(self, frame, detections):
        cv2.drawContours(frame, self._contours, -1, (0, 255, 128), 2)
        for d in detections:
            cv2.circle(frame, (int(d["x"]), int(d["y"])), 7, (0, 200, 255), -1)
        return frame

    # ------------------------------------------------------------------
    def get_trackbar_settings(self):
        return [
            {"name": "History",    "max": 1000, "default": 200},
            {"name": "Var Thresh", "max": 100,  "default": 16},
            {"name": "Min Area",   "max": 10000,"default": 500},
            {"name": "Blur",       "max": 10,   "default": 5},
            {"name": "Dilate",     "max": 10,   "default": 3},
        ]

    def on_trackbar(self, name, value):
        if   name == "History":    self._history    = max(10, value); self._init_bg()
        elif name == "Var Thresh": self._var_thresh  = max(1,  value); self._init_bg()
        elif name == "Min Area":   self._min_area   = max(1,  value)
        elif name == "Blur":       self._blur       = value
        elif name == "Dilate":     self._dilate     = value

    def reset(self):
        self._init_bg()
