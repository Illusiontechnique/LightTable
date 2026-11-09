"""On-demand, shared JPEG previews using frames from the existing capture loop."""

import threading
import time

import cv2


class OperatorPreview:
    MODES = ("camera", "overlay", "motion")
    LEASE_SECONDS = 2.0
    INTERVAL = 0.2

    def __init__(self):
        self._condition = threading.Condition()
        self._leases = {}
        self._last_submitted = {}
        self._images = {}
        self._pending = None
        self._closed = False
        self._thread = None

    def request(self, mode):
        now = time.monotonic()
        with self._condition:
            self._leases[mode] = now
            image = self._images.get(mode)
            if image and now - image[0] < self.LEASE_SECONDS:
                return image[1], image[2]
        return None

    def wants(self, mode):
        now = time.monotonic()
        with self._condition:
            return (now - self._leases.get(mode, 0) < self.LEASE_SECONDS
                    and now - self._last_submitted.get(mode, 0) >= self.INTERVAL)

    def submit(self, images, context=""):
        now = time.monotonic()
        with self._condition:
            selected = {
                mode: frame.copy() for mode, frame in images.items()
                if now - self._leases.get(mode, 0) < self.LEASE_SECONDS
                and now - self._last_submitted.get(mode, 0) >= self.INTERVAL
            }
            if selected:
                if self._thread is None:
                    self._thread = threading.Thread(target=self._encode, name="operator-preview", daemon=True)
                    self._thread.start()
                for mode in selected:
                    self._last_submitted[mode] = now
                self._pending = (selected, context)
                self._condition.notify()

    def _encode(self):
        while True:
            with self._condition:
                while self._pending is None and not self._closed:
                    self._condition.wait()
                if self._closed:
                    return
                pending, context = self._pending
                self._pending = None
            for mode, frame in pending.items():
                height, width = frame.shape[:2]
                scale = min(320 / width, 240 / height, 1.0)
                if scale < 1:
                    frame = cv2.resize(frame, (max(1, round(width * scale)),
                                                max(1, round(height * scale))),
                                       interpolation=cv2.INTER_AREA)
                try:
                    ok, encoded = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 75])
                except cv2.error as exc:
                    print(f"[Preview] JPEG encoding failed for {mode}: {exc}")
                    continue
                if not ok:
                    print(f"[Preview] JPEG encoding failed for {mode}")
                    continue
                with self._condition:
                    self._images[mode] = (time.monotonic(), encoded.tobytes(), context)

    def close(self):
        with self._condition:
            self._closed = True
            self._pending = None
            self._condition.notify()
        if self._thread:
            self._thread.join(timeout=2)
