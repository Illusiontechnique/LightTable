import cv2
import numpy as np
from .base_tracker import BaseTracker


class BlobTracker(BaseTracker):
    """
    OpenCV SimpleBlobDetector — finds circular/round blobs by area, circularity,
    and intensity threshold.  Works well for bright fingertips on a dark surface
    or round markers.  Toggle Invert to detect dark blobs on a bright background.
    """

    name = "Blob Detection"

    def __init__(self):
        self._min_area     = 200
        self._max_area     = 20000
        self._circularity  = 20    # trackbar 0-100 → 0.0-1.0
        self._threshold    = 100   # min intensity threshold for blob detection
        self._invert       = 0
        self._last_kp      = []
        self._init_detector()

    # ------------------------------------------------------------------
    def _init_detector(self):
        p = cv2.SimpleBlobDetector_Params()
        p.filterByArea        = True
        p.minArea             = float(max(1, self._min_area))
        p.maxArea             = float(max(self._min_area + 1, self._max_area))
        p.filterByCircularity = True
        p.minCircularity      = self._circularity / 100.0
        p.filterByConvexity   = False
        p.filterByInertia     = False
        p.minThreshold        = float(self._threshold)
        p.maxThreshold        = 255.0
        self.detector = cv2.SimpleBlobDetector_create(p)

    # ------------------------------------------------------------------
    def process(self, frame) -> list:
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        if self._invert:
            gray = cv2.bitwise_not(gray)
        self._last_kp = self.detector.detect(gray)
        return [
            {"id": i, "x": kp.pt[0], "y": kp.pt[1], "size": kp.size}
            for i, kp in enumerate(self._last_kp)
        ]

    def draw_debug(self, frame, detections):
        return cv2.drawKeypoints(
            frame, self._last_kp, np.zeros((1,)),
            (0, 60, 255), cv2.DRAW_MATCHES_FLAGS_DRAW_RICH_KEYPOINTS,
        )

    # ------------------------------------------------------------------
    def get_trackbar_settings(self):
        return [
            {"name": "Min Area",    "max": 5000,  "default": 200},
            {"name": "Max Area",    "max": 50000, "default": 20000},
            {"name": "Circularity", "max": 100,   "default": 20},
            {"name": "Threshold",   "max": 255,   "default": 100},
            {"name": "Invert",      "max": 1,     "default": 0},
        ]

    def on_trackbar(self, name, value):
        if   name == "Min Area":    self._min_area    = value;            self._init_detector()
        elif name == "Max Area":    self._max_area    = max(10, value);   self._init_detector()
        elif name == "Circularity": self._circularity = value;            self._init_detector()
        elif name == "Threshold":   self._threshold   = value;            self._init_detector()
        elif name == "Invert":      self._invert      = value

    def reset(self):
        self._last_kp = []
        self._init_detector()
