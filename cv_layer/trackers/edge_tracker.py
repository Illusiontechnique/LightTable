import cv2
import numpy as np
from .base_tracker import BaseTracker


class EdgeTracker(BaseTracker):
    """
    Canny edge detection + contour centroid extraction.
    Detects any object with a strong edge boundary — handles objects of any color
    as long as they have contrast against the background.

    Adjust Canny Low/High for edge sensitivity (Canny recommends High ≈ 2-3× Low).
    Min Area filters out noise.  Dilate connects fragmented edge lines.
    Enable 'Show Mask' to see the raw edge image for tuning.
    """

    name = "Edge / Canny"

    def __init__(self):
        self._low     = 50
        self._high    = 150
        self._min_area = 300
        self._blur    = 2
        self._dilate  = 2
        self._contours = []
        self._mask     = None

    # ------------------------------------------------------------------
    def process(self, frame) -> list:
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        k    = self._blur * 2 + 1
        blur = cv2.GaussianBlur(gray, (k, k), 0)
        edges = cv2.Canny(blur, self._low, self._high)

        dk     = self._dilate * 2 + 1
        kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (dk, dk))
        edges  = cv2.dilate(edges, kernel)
        self._mask = edges

        contours, _ = cv2.findContours(edges, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
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
        # Overlay edges as a semi-transparent green tint
        green_edges         = np.zeros_like(frame)
        green_edges[:, :, 1] = self._mask
        frame = cv2.addWeighted(frame, 0.75, green_edges, 0.8, 0)
        cv2.drawContours(frame, self._contours, -1, (0, 220, 100), 1)
        for d in detections:
            cv2.circle(frame, (int(d["x"]), int(d["y"])), 5, (0, 255, 100), -1)
        return frame

    # ------------------------------------------------------------------
    def get_trackbar_settings(self):
        return [
            {"name": "Canny Low",  "max": 255,  "default": 50},
            {"name": "Canny High", "max": 255,  "default": 150},
            {"name": "Min Area",   "max": 5000, "default": 300},
            {"name": "Blur",       "max": 10,   "default": 2},
            {"name": "Dilate",     "max": 10,   "default": 2},
        ]

    def on_trackbar(self, name, value):
        attr_map = {
            "Canny Low":  "_low",   "Canny High": "_high",
            "Min Area":   "_min_area", "Blur": "_blur", "Dilate": "_dilate",
        }
        if name in attr_map:
            setattr(self, attr_map[name], value)

    def reset(self):
        self._contours = []
        self._mask     = None
