import cv2
from .base_tracker import BaseTracker


def _make_csrt():
    """Create a CSRT tracker, falling back to KCF if contrib is unavailable."""
    for fn in (
        lambda: cv2.TrackerCSRT_create(),
        lambda: cv2.legacy.TrackerCSRT_create(),
        lambda: cv2.legacy.TrackerKCF_create(),
    ):
        try:
            return fn()
        except AttributeError:
            continue
    raise RuntimeError(
        "No OpenCV CSRT/KCF tracker found.  "
        "Install opencv-contrib-python: pip install opencv-contrib-python"
    )


class ObjectTracker(BaseTracker):
    """
    CSRT (Channel and Spatial Reliability Tracker) — per-object discriminative
    tracker.  Once you lock on to a region, it follows it reliably through
    partial occlusion, scale changes, and rotation.

    Keys (in the main CV window):
      'a'  — freeze frame & draw a bounding box with the mouse to add a tracked object
      'x'  — clear all tracked objects
    """

    name = "Object Tracking (CSRT)"

    def __init__(self):
        self._trackers  = []   # list of [id, tracker, (x,y,w,h)]
        self._next_id   = 0

    # ------------------------------------------------------------------
    def add_object(self, frame, bbox):
        """
        Add a new object.  bbox = (x, y, w, h) as returned by cv2.selectROI.
        Returns the assigned tracking ID, or -1 if bbox is invalid.
        """
        if bbox[2] <= 0 or bbox[3] <= 0:
            return -1
        t = _make_csrt()
        t.init(frame, tuple(int(v) for v in bbox))
        obj_id = self._next_id
        self._next_id += 1
        self._trackers.append([obj_id, t, tuple(int(v) for v in bbox)])
        print(f"[ObjectTracker] Added object #{obj_id}  bbox={bbox}")
        return obj_id

    def clear(self):
        self._trackers = []
        self._next_id  = 0

    # ------------------------------------------------------------------
    def process(self, frame) -> list:
        detections = []
        to_remove  = []
        for i, (obj_id, t, _) in enumerate(self._trackers):
            ok, bbox = t.update(frame)
            if ok:
                x, y, w, h = (int(v) for v in bbox)
                self._trackers[i][2] = (x, y, w, h)
                detections.append({"id": obj_id, "x": x + w / 2, "y": y + h / 2, "bbox": (x, y, w, h)})
            else:
                to_remove.append(i)
        for i in reversed(to_remove):
            print(f"[ObjectTracker] Lost object #{self._trackers[i][0]}")
            self._trackers.pop(i)
        return detections

    def draw_debug(self, frame, detections):
        for d in detections:
            x, y, w, h = d["bbox"]
            cv2.rectangle(frame, (x, y), (x + w, y + h), (0, 255, 200), 2)
            cv2.putText(frame, f"#{d['id']}",
                        (x, y - 6), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 200), 1)
        cv2.putText(frame,
                    f"'a' add object  |  'x' clear all  |  tracking: {len(self._trackers)}",
                    (10, frame.shape[0] - 15),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (180, 180, 180), 1)
        return frame

    # ------------------------------------------------------------------
    def get_trackbar_settings(self):
        return []   # no per-param tuning needed for CSRT

    def reset(self):
        self.clear()
