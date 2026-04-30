import cv2
import numpy as np
from .base_tracker import BaseTracker


class ColorTracker(BaseTracker):
    """
    HSV color-range masking — tracks any object within a user-defined hue/saturation/
    value band.  Default range targets orange-ish skin tones.  Use 'Show Mask' in
    Settings to tune H/S/V sliders until the desired color fills white in the mask.

    Tips for tuning:
      H (hue 0-180 in OpenCV): red≈0, orange≈15, yellow≈30, green≈60, blue≈120
      S (saturation): low S = washed out / grey, high S = vivid color
      V (value):      low V = dark,  high V = bright
    """

    name = "Color Tracking"

    def __init__(self):
        # Default: skin-tone orange band
        self._h_low   = 0
        self._h_high  = 25
        self._s_low   = 40
        self._s_high  = 255
        self._v_low   = 60
        self._v_high  = 255
        self._min_area = 300
        self._blur    = 5
        self._dilate  = 3
        self._contours = []
        self._mask     = None

    # ------------------------------------------------------------------
    def process(self, frame) -> list:
        k       = self._blur * 2 + 1
        blurred = cv2.GaussianBlur(frame, (k, k), 0)
        hsv     = cv2.cvtColor(blurred, cv2.COLOR_BGR2HSV)

        lower = np.array([self._h_low,  self._s_low,  self._v_low],  dtype=np.uint8)
        upper = np.array([self._h_high, self._s_high, self._v_high], dtype=np.uint8)
        mask  = cv2.inRange(hsv, lower, upper)

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
        cv2.drawContours(frame, self._contours, -1, (255, 100, 0), 2)
        for d in detections:
            cv2.circle(frame, (int(d["x"]), int(d["y"])), 7, (255, 220, 0), -1)
        return frame

    # ------------------------------------------------------------------
    def get_trackbar_settings(self):
        return [
            {"name": "H Low",    "max": 180,   "default": 0},
            {"name": "H High",   "max": 180,   "default": 25},
            {"name": "S Low",    "max": 255,   "default": 40},
            {"name": "S High",   "max": 255,   "default": 255},
            {"name": "V Low",    "max": 255,   "default": 60},
            {"name": "V High",   "max": 255,   "default": 255},
            {"name": "Min Area", "max": 10000, "default": 300},
            {"name": "Blur",     "max": 10,    "default": 5},
            {"name": "Dilate",   "max": 10,    "default": 3},
        ]

    def on_trackbar(self, name, value):
        attr_map = {
            "H Low":    "_h_low",   "H High":   "_h_high",
            "S Low":    "_s_low",   "S High":   "_s_high",
            "V Low":    "_v_low",   "V High":   "_v_high",
            "Min Area": "_min_area","Blur":     "_blur",
            "Dilate":   "_dilate",
        }
        if name in attr_map:
            setattr(self, attr_map[name], value)

    def reset(self):
        self._contours = []
        self._mask     = None
