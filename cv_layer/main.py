import cv2
import numpy as np
import time

from bridge         import InteractionBridge
from calibration    import Calibration
from control_window import ControlWindow, TRACKER_NAMES, SMOOTH_LABELS
from smoothing      import KalmanSmoother, ExponentialSmoother
from web_remote     import ControlState, WebRemote
from trackers       import (
    HandTracker, BlobTracker, MotionTracker,
    ColorTracker, EdgeTracker, ObjectTracker,
)

# Order must match TRACKER_NAMES in control_window.py
TRACKER_CLASSES = [
    HandTracker,
    BlobTracker,
    MotionTracker,
    ColorTracker,
    EdgeTracker,
    ObjectTracker,
]


class LightTableCV:

    def __init__(self, osc_ip="127.0.0.1", osc_port=7000):
        self.bridge      = InteractionBridge(osc_ip, osc_port)
        self.calibration = Calibration()
        self.ui          = ControlWindow()
        self.kalman      = KalmanSmoother()
        self.ema         = ExponentialSmoother(alpha=0.35)

        self._tracker_idx  = 0
        self._cam_idx      = 0
        self._current_res  = (640, 480)
        self.tracker       = TRACKER_CLASSES[0]()
        self.ui.rebuild_for_tracker(self.tracker)
        self._last_detection_count = 0

        # Phone web remote
        self._ctrl_state = ControlState()
        self._remote     = WebRemote(self._ctrl_state, godot_host=osc_ip, godot_port=osc_port)

    # ------------------------------------------------------------------
    # OSC output
    # ------------------------------------------------------------------
    def send_interaction(self, id, x, y, state="move"):
        cal_x, cal_y = self.calibration.apply(x, y)
        norm_x = float(np.clip(cal_x / 1920.0, 0.0, 1.0))
        norm_y = float(np.clip(cal_y / 1080.0, 0.0, 1.0))
        self.bridge.send({
            "type":  "interaction",
            "id":    id,
            "x":     norm_x,
            "y":     norm_y,
            "state": state,
        })

    # ------------------------------------------------------------------
    # Smoothing
    # ------------------------------------------------------------------
    def _smooth(self, mode: int, ema_raw: int, detections: list) -> list:
        """Apply per-ID smoothing.  mode: 0=none  1=EMA  2=Kalman."""
        if mode == 0:
            return detections
        self.ema.set_alpha(max(0.05, ema_raw / 100.0))
        out = []
        for d in detections:
            if mode == 1:
                sx, sy = self.ema.smooth(d["id"], d["x"], d["y"])
            else:
                sx, sy = self.kalman.smooth(d["id"], d["x"], d["y"])
            out.append({**d, "x": sx, "y": sy})
        return out

    # ------------------------------------------------------------------
    # Frame pre-processing
    # ------------------------------------------------------------------
    def _adjust_frame(self, frame, s: dict):
        if s["Flip H"]:
            frame = cv2.flip(frame, 1)
        alpha = s["Contrast"]   / 50.0   # 0-2, neutral at 1.0
        beta  = s["Brightness"] - 50     # -50..+50 offset
        return cv2.convertScaleAbs(frame, alpha=alpha, beta=beta)

    # Mouse callback no longer needed — calibration uses Tkinter click binding

    # ------------------------------------------------------------------
    # Main per-frame processing (tracker runs on clean frame; overlays on display)
    # ------------------------------------------------------------------
    def process_frame(self, frame, settings: dict):
        # 1. Run tracker on the adjusted (but overlay-free) frame
        detections = self.tracker.process(frame)
        detections = self._smooth(settings["Smoothing"], settings["EMA Respons"], detections)
        self._last_detection_count = len(detections)   # expose for status reporting

        # 2. Build display image
        if settings["Show Mask"] and hasattr(self.tracker, "_mask") and self.tracker._mask is not None:
            display = cv2.cvtColor(self.tracker._mask, cv2.COLOR_GRAY2BGR)
        else:
            display = self.tracker.draw_debug(frame.copy(), detections)

        # 3. Calibration overlay
        corner_labels = ["TL", "TR", "BR", "BL"]
        for i, p in enumerate(self.calibration.points):
            cv2.circle(display, tuple(p), 7, (0, 255, 0), -1)
            cv2.putText(display, corner_labels[i],
                        (p[0] + 10, p[1] + 12),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)

        if len(self.calibration.points) < 4:
            labels = ["Top-Left", "Top-Right", "Bottom-Right", "Bottom-Left"]
            msg = (f"CALIBRATE {len(self.calibration.points)+1}/4 "
                   f"— click {labels[len(self.calibration.points)]}")
            cv2.putText(display, msg, (20, 38),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 50, 255), 2)
        else:
            cv2.putText(display, "Calibrated  [c]=reset", (20, 38),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 220, 0), 1)

        # 4. HUD
        smooth_lbl = SMOOTH_LABELS[settings["Smoothing"]]
        hud = (f"[ {self.tracker.name} ]   "
               f"Smooth: {smooth_lbl}   "
               f"Detections: {len(detections)}")
        cv2.putText(display, hud,
                    (10, display.shape[0] - 12),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1)

        # 5. Send interactions over OSC
        for d in detections:
            self.send_interaction(d["id"], d["x"], d["y"])

        # 6. Send hand skeleton landmarks (HandTracker only)
        if isinstance(self.tracker, HandTracker):
            res = self.tracker._last_results
            if res and res.multi_hand_landmarks:
                hands_out = []
                for lm in res.multi_hand_landmarks:
                    pts = [{"x": round(pt.x, 4), "y": round(pt.y, 4)}
                           for pt in lm.landmark]
                    hands_out.append(pts)
                self.bridge.send({"type": "hand_skeleton", "hands": hands_out})
            else:
                self.bridge.send({"type": "hand_skeleton", "hands": []})

        return display

    # ------------------------------------------------------------------
    # Camera helpers
    # ------------------------------------------------------------------
    def _open_cap(self, idx: int):
        """Open camera at idx and verify a frame can actually be read.
        Returns the cap if working, or a released cap object if not."""
        cap = cv2.VideoCapture(idx)
        if not cap.isOpened():
            return cap
        # MSMF on Windows sometimes reports isOpened()=True but fails to
        # deliver frames (e.g. camera held by another process / IR sensor).
        # Drain up to 5 frames with brief sleeps to confirm the stream works.
        for _ in range(5):
            ok, _ = cap.read()
            if ok:
                self._cam_idx = idx
                return cap
            time.sleep(0.12)
        cap.release()
        return cv2.VideoCapture(-1)   # guaranteed not-opened

    def _auto_open_cap(self):
        """Scan indices 0-9 and return the first camera that delivers frames."""
        for idx in range(10):
            cap = self._open_cap(idx)
            if cap.isOpened():
                print(f"Camera {idx} opened successfully.")
                return cap
        return cv2.VideoCapture(-1)   # nothing found

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------
    def run(self):
        cap = self._auto_open_cap()
        if not cap.isOpened():
            print("WARNING: No camera found.  Running virtual simulation...")
            self.run_virtual_sim()
            return

        # Register calibration click handler on preview label
        def _on_click(x: int, y: int):
            if len(self.calibration.points) < 4:
                self.calibration.points.append([x, y])
                print(f"[{len(self.calibration.points)}/4] Calibration point: ({x}, {y})")
                if len(self.calibration.points) == 4:
                    self.calibration.get_warp_matrix((1, 1))
                    print("--- CALIBRATION COMPLETE ---")

        self.ui.set_click_callback(_on_click)

        # Start phone web remote
        self._remote.start()
        print(f"\nWeb remote: {self._remote.get_url()}  (PIN in remote_config.json)")

        print("\nLightTable CV ready.")
        print("  Esc / q    quit")
        print("  c          reset calibration")
        print("  a          freeze & select object  (Object tracker only)")
        print("  x          clear tracked objects   (Object tracker only)\n")

        while cap.isOpened() and self.ui.is_open():
            ok, frame = cap.read()
            if not ok:
                break

            settings = self.ui.read()

            # ---- Tracker switch ----
            new_tidx = settings["Tracker"]
            if new_tidx != self._tracker_idx:
                self._tracker_idx = new_tidx
                self.tracker = TRACKER_CLASSES[new_tidx]()
                self.ui.rebuild_for_tracker(self.tracker)
                self.kalman.clear()
                self.ema.clear()

            # ---- Camera switch ----
            new_cidx = settings["Camera Idx"]
            if new_cidx != self._cam_idx:
                cap.release()
                new_cap = self._open_cap(new_cidx)
                if new_cap.isOpened():
                    cap = new_cap
                    self.tracker.reset()
                else:
                    prev = self._cam_idx
                    print(f"Camera {new_cidx} unavailable, staying on {prev}")
                    cap = self._open_cap(prev)

            # ---- Resolution change ----
            new_res = settings["Resolution"]
            if new_res != self._current_res:
                cap.set(cv2.CAP_PROP_FRAME_WIDTH,  new_res[0])
                cap.set(cv2.CAP_PROP_FRAME_HEIGHT, new_res[1])
                self._current_res = new_res

            # ---- Remote tracker change (phone web remote) ----
            remote_tidx = self._ctrl_state.pop_tracker_request()
            if remote_tidx is not None and remote_tidx != self._tracker_idx:
                self._tracker_idx = remote_tidx
                self.tracker = TRACKER_CLASSES[remote_tidx]()
                self.ui.rebuild_for_tracker(self.tracker)
                self.kalman.clear()
                self.ema.clear()

            frame   = self._adjust_frame(frame, settings)
            display = self.process_frame(frame, settings)

            # Update status for web remote
            self._ctrl_state.update_status(
                audio       = 0.0,   # audio is Godot-side; CV doesn't measure it
                tracker_idx = self._tracker_idx,
                detections  = getattr(self, "_last_detection_count", 0),
            )

            # Push to unified Tkinter preview (no-op when hidden)
            self.ui.update_preview(display)

            # Drive Tkinter event loop; collect keypresses
            keys = self.ui.tick()

            if "esc" in keys or "q" in keys:
                break
            if "c" in keys:
                self.calibration.points = []
            if "a" in keys and isinstance(self.tracker, ObjectTracker):
                ok2, freeze = cap.read()
                if ok2:
                    freeze = self._adjust_frame(freeze, settings)
                    win_sel = "Select Object (Enter=confirm  Esc=cancel)"
                    bbox = cv2.selectROI(win_sel, freeze, fromCenter=False, showCrosshair=True)
                    cv2.destroyWindow(win_sel)
                    self.tracker.add_object(freeze, bbox)
            if "x" in keys and isinstance(self.tracker, ObjectTracker):
                self.tracker.clear()
                print("Object tracker cleared.")

        cap.release()
        cv2.destroyAllWindows()

    # ------------------------------------------------------------------
    # Headless virtual simulation
    # ------------------------------------------------------------------
    def run_virtual_sim(self):
        print("Virtual simulation running (Ctrl+C to stop)...")
        t = 0.0
        try:
            while True:
                t += 0.05
                self.send_interaction(
                    0,
                    (0.5 + 0.3 * np.sin(t)) * 1920,
                    (0.5 + 0.3 * np.cos(t)) * 1080,
                )
                time.sleep(0.016)
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    LightTableCV().run()

