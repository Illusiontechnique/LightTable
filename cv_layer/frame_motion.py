"""Low-resolution frame differencing, independent of the selected tracker."""

import cv2
import numpy as np


class FrameMotion:
    def __init__(self, size=(160, 120), max_points=8, interval=0.1):
        self.size = size
        self.max_points = max_points
        self.interval = interval
        self.reset()

    def reset(self):
        self.previous = None
        self.last_time = None

    def update(self, frame, timestamp, threshold=25, min_percent=1, region=None):
        if self.last_time is not None and timestamp - self.last_time < self.interval:
            return None
        width, height = self.size
        gray = cv2.cvtColor(cv2.resize(frame, self.size, interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
        gray = cv2.GaussianBlur(gray, (5, 5), 0)
        previous = self.previous
        self.previous, self.last_time = gray, timestamp
        if previous is None:
            return {"amount": 0.0, "points": []}

        diff = cv2.absdiff(gray, previous)
        mask = cv2.threshold(diff, threshold, 255, cv2.THRESH_BINARY)[1]
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
        region_mask = np.full((height, width), 255, dtype=np.uint8)
        if region is not None:
            region_mask.fill(0)
            source_h, source_w = frame.shape[:2]
            polygon = np.asarray([
                (round(x * width / source_w), round(y * height / source_h))
                for x, y in region
            ], dtype=np.int32)
            cv2.fillConvexPoly(region_mask, polygon, 255)
        mask = cv2.bitwise_and(mask, region_mask)
        valid_pixels = max(1, cv2.countNonZero(region_mask))
        amount = cv2.countNonZero(mask) / valid_pixels
        if amount * 100 < min_percent:
            return {"amount": 0.0, "points": []}

        # Sample the boundary of changed regions in spatial tiles, rather than
        # sending one centroid for the entire moving object.
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        edge = np.zeros_like(mask)
        cv2.drawContours(edge, contours, -1, 255, 1)
        tiles = []
        for row in range(3):
            for col in range(4):
                x0, x1 = col * width // 4, (col + 1) * width // 4
                y0, y1 = row * height // 3, (row + 1) * height // 3
                ys, xs = np.nonzero(edge[y0:y1, x0:x1])
                if len(xs):
                    middle = len(xs) // 2
                    tiles.append((len(xs), (x0 + int(xs[middle]), y0 + int(ys[middle]))))
        tiles.sort(key=lambda item: item[0], reverse=True)
        source_h, source_w = frame.shape[:2]
        points = [(x * source_w / width, y * source_h / height)
                  for _, (x, y) in tiles[:self.max_points]]
        return {"amount": float(amount), "points": points}
