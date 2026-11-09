import cv2
import numpy as np
import time
from collections import deque

from bridge         import InteractionBridge
from calibration    import Calibration
from control_window import ControlWindow, TRACKER_NAMES, SMOOTH_LABELS
from smoothing      import KalmanSmoother, ExponentialSmoother
from tracking       import TrackingManager, InteractionEventGenerator
from frame_motion   import FrameMotion
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
        self.tracking    = TrackingManager()
        self.interactions = InteractionEventGenerator()
        self.frame_motion = FrameMotion()

        self._tracker_idx  = 0
        self._cam_idx      = 0
        self._current_res  = (640, 480)
        self.tracker       = TRACKER_CLASSES[0]()
        self.ui.rebuild_for_tracker(self.tracker)
        self._last_detection_count = 0
        self._last_skeleton_send   = 0.0   # throttle: max 20 fps
        self._capture_times = deque(maxlen=30)
        self._processing_times = deque(maxlen=30)
        self._last_udp_ok = None
        self._tracker_error = None
        self._camera_connected = False
        self._motion_enabled = False

        # Phone web remote
        self._ctrl_state = ControlState()
        self._remote     = WebRemote(self._ctrl_state, godot_host=osc_ip, godot_port=osc_port)
        self.ui.set_calibration_action_callback(self._calibration_action)

    # ------------------------------------------------------------------
    # JSON-over-UDP output
    # ------------------------------------------------------------------
    def send_interaction(self, id, x, y, state="move", pointers=True, **metadata):
        cal_x, cal_y = self.calibration.apply(x, y)
        if self.calibration.state == Calibration.CALIBRATED:
            # Calibration warp maps to 1920×1080 space
            norm_x = float(np.clip(cal_x / 1920.0, 0.0, 1.0))
            norm_y = float(np.clip(cal_y / 1080.0, 0.0, 1.0))
        else:
            # No calibration: normalize by the actual processing resolution
            res_w, res_h = self._current_res
            norm_x = float(np.clip(cal_x / res_w, 0.0, 1.0))
            norm_y = float(np.clip(cal_y / res_h, 0.0, 1.0))
        packet = {
            "type":      "interaction",
            "id":        id,
            "x":         norm_x,
            "y":         norm_y,
            "state":     state,
            "event":     state,
            "pointers":  pointers,
            "tracker":   self.tracker.name,
            "timestamp": time.monotonic(),
        }
        packet.update(metadata)
        self._send(packet)

    def _send(self, packet):
        try:
            self.bridge.send(packet)
            self._last_udp_ok = True
            return True
        except OSError as exc:
            self._last_udp_ok = False
            print(f"[UDP] Could not send packet to Godot: {exc}")
            return False

    def _send_event(self, event, pointers=True):
        event["pointers"] = pointers
        self._send(event)

    def _send_motion_frame(self):
        calibrated = self.calibration.state == Calibration.CALIBRATED
        data = self.frame_motion.projection_frame(
            self._current_res,
            self.calibration.matrix if calibrated else None,
            self.calibration.target_size if calibrated else None,
        )
        try:
            self.bridge.send_motion_frame(data)
        except OSError as exc:
            if self._last_udp_ok is not False:
                print(f"[UDP] Could not send motion frame: {exc}")
            self._last_udp_ok = False

    def _normalize_point(self, x, y):
        x, y = self.calibration.apply(x, y)
        if self.calibration.state == Calibration.CALIBRATED:
            width, height = self.calibration.target_size
        else:
            width, height = self._current_res
        return float(np.clip(x / width, 0.0, 1.0)), float(np.clip(y / height, 0.0, 1.0))

    # ------------------------------------------------------------------
    # Smoothing
    # ------------------------------------------------------------------
    def _smooth(self, mode: int, ema_raw: int, detections: list, timestamp: float) -> list:
        """Apply per-ID smoothing.  mode: 0=none  1=EMA  2=Kalman."""
        if mode == 0:
            return detections
        self.ema.set_alpha(max(0.05, ema_raw / 100.0))
        out = []
        for d in detections:
            if mode == 1:
                sx, sy = self.ema.smooth(d["id"], d["x"], d["y"])
            else:
                sx, sy = self.kalman.smooth(d["id"], d["x"], d["y"], timestamp)
            out.append({**d, "x": sx, "y": sy})
        return out

    # ------------------------------------------------------------------
    # Frame pre-processing
    # ------------------------------------------------------------------
    def _adjust_frame(self, frame, s: dict):
        if s["Flip H"]:
            frame = cv2.flip(frame, 1)
        # Downscale to selected processing resolution (actual reduction, not crop)
        target_w, target_h = self._current_res
        h, w = frame.shape[:2]
        if (w, h) != (target_w, target_h):
            frame = cv2.resize(frame, (target_w, target_h), interpolation=cv2.INTER_AREA)
        alpha = s["Contrast"]   / 50.0   # 0-2, neutral at 1.0
        beta  = s["Brightness"] - 50     # -50..+50 offset
        return cv2.convertScaleAbs(frame, alpha=alpha, beta=beta)

    # Mouse callback no longer needed — calibration uses Tkinter click binding

    # ------------------------------------------------------------------
    # Main per-frame processing (tracker runs on clean frame; overlays on display)
    # ------------------------------------------------------------------
    def process_frame(self, frame, settings: dict, timestamp=None):
        timestamp = time.monotonic() if timestamp is None else timestamp
        processing_started = time.perf_counter()
        self.tracking.max_distance = max(
            120.0, float(np.hypot(*self._current_res)) * 0.12
        )
        # 1. Run tracker on the adjusted (but overlay-free) frame
        try:
            raw_detections = self.tracker.process(frame)
            self._tracker_error = None
        except Exception as exc:
            if self._tracker_error != str(exc):
                print(f"[Tracker] {self.tracker.name} failed for this frame: {exc}")
                self._tracker_error = str(exc)
            raw_detections = []
        detections, expired = self.tracking.update(raw_detections, timestamp)
        for track_id in expired:
            self.ema.clear(track_id)
            self.kalman.clear(track_id)
        detections = self._smooth(
            settings["Smoothing"], settings["EMA Respons"], detections, timestamp
        )
        self._last_detection_count = len(detections)   # expose for status reporting

        # 2. Build display image
        if self.calibration.state == Calibration.SELECTING:
            display = frame.copy()
        elif settings["Show Mask"] and hasattr(self.tracker, "_mask") and self.tracker._mask is not None:
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

        if len(self.calibration.points) >= 3:
            cv2.polylines(
                display, [np.asarray(self.calibration.points, dtype=np.int32)],
                len(self.calibration.points) == 4, (0, 220, 255), 2,
            )
        status_color = (0, 220, 0) if self.calibration.state == Calibration.CALIBRATED else (0, 80, 255)
        cv2.putText(display, f"{self.calibration.state.upper()}: {self.calibration.message}",
                    (20, 38), cv2.FONT_HERSHEY_SIMPLEX, 0.48, status_color, 1)

        # 4. HUD
        smooth_lbl = SMOOTH_LABELS[settings["Smoothing"]]
        hud = (f"[ {self.tracker.name} ]   "
               f"Smooth: {smooth_lbl}   "
               f"Detections: {len(detections)}")
        cv2.putText(display, hud,
                    (10, display.shape[0] - 12),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1)

        # 5. Convert stabilized detections to normalized interaction points.
        normalized = []
        for detection in detections:
            x, y = self._normalize_point(detection["x"], detection["y"])
            point = {
                "id": detection["id"],
                "x": float(np.clip(x, 0.0, 1.0)),
                "y": float(np.clip(y, 0.0, 1.0)),
                "tracker": self.tracker.name,
                "timestamp": timestamp,
                "confidence": detection.get("confidence"),
            }
            normalized.append(point)
        interaction_points = (
            [] if self.calibration.state in (Calibration.SELECTING, Calibration.VALIDATING)
            else normalized
        )
        for event in self.interactions.update(interaction_points, timestamp):
            self._send_event(event, settings.get("Pointers", True))

        motion_enabled = settings.get("Frame Motion", True) and self.calibration.state not in (
            Calibration.SELECTING, Calibration.VALIDATING
        )
        if motion_enabled:
            region = self.calibration.points if self.calibration.state == Calibration.CALIBRATED else None
            motion = self.frame_motion.update(
                frame, timestamp, settings.get("Motion Threshold", 25),
                settings.get("Motion Min Percent", 1), region,
            )
            if motion is not None:
                self._send_motion_frame()
                points = []
                for x, y in motion["points"]:
                    nx, ny = self._normalize_point(x, y)
                    points.append({"x": nx, "y": ny})
                self._send({"type": "frame_motion", "amount": motion["amount"], "points": points})
        elif self._motion_enabled:
            self.frame_motion.reset()
            self._send_motion_frame()
            self._send({"type": "frame_motion", "amount": 0.0, "points": []})
        self._motion_enabled = motion_enabled

        # 6. Send hand skeleton landmarks (HandTracker only, throttled to ~20 fps)
        if isinstance(self.tracker, HandTracker):
            now = time.time()
            if now - self._last_skeleton_send >= 0.05:
                self._last_skeleton_send = now
                res = self.tracker._last_results
                if res and res.multi_hand_landmarks:
                    hands_out = []
                    for lm in res.multi_hand_landmarks:
                        pts = []
                        for pt in lm.landmark:
                            x, y = self._normalize_point(
                                pt.x * self._current_res[0], pt.y * self._current_res[1]
                            )
                            pts.append({"x": round(x, 4), "y": round(y, 4)})
                        hands_out.append(pts)
                    self._send({"type": "hand_skeleton", "hands": hands_out})
                else:
                    self._send({"type": "hand_skeleton", "hands": []})

        self._processing_times.append(time.perf_counter() - processing_started)
        self.ui.update_calibration_status(
            self.calibration.state, self.calibration.message,
            self._cam_idx, self._current_res,
        )

        return display

    def _calibration_action(self, action):
        self.frame_motion.reset()
        self._send_motion_frame()
        if action == "start":
            self.calibration.start()
        elif action == "undo":
            self.calibration.undo()
        elif action == "reset":
            self.calibration.reset()
        elif action == "cancel":
            self.calibration.cancel()
        elif action == "save":
            try:
                self.calibration.save()
            except (OSError, ValueError) as exc:
                self.calibration.message = f"Could not save calibration: {exc}"
        elif action == "load":
            self.calibration.load_profile()
        self.ui.update_calibration_status(
            self.calibration.state, self.calibration.message,
            self._cam_idx, self._current_res,
        )

    def _set_calibration_context(self, source_size, settings):
        signature = Calibration.make_signature(
            self._cam_idx, source_size, self._current_res, settings["Flip H"]
        )
        if signature != self.calibration.signature:
            self.frame_motion.reset()
            for event in self.interactions.close_all(time.monotonic()):
                self._send_event(event, settings.get("Pointers", True))
            self.calibration.set_context(signature)
            self.tracking.reset()
            self.ema.clear()
            self.kalman.clear()
            self.ui.update_calibration_status(
                self.calibration.state, self.calibration.message,
                self._cam_idx, self._current_res,
            )

    def _switch_tracker(self, index, pointers=True):
        if not 0 <= index < len(TRACKER_CLASSES):
            return False
        try:
            replacement = TRACKER_CLASSES[index]()
        except Exception as exc:
            print(f"[Tracker] Could not initialize {TRACKER_NAMES[index]}: {exc}")
            self.ui.rebuild_for_tracker(self.tracker)
            return False
        for event in self.interactions.close_all(time.monotonic()):
            self._send_event(event, pointers)
        if hasattr(self.tracker, "close"):
            self.tracker.close()
        self.tracker = replacement
        self._tracker_idx = index
        self.ui.rebuild_for_tracker(self.tracker)
        self._send({"type": "track_mode_change", "mode": self.tracker.name})
        self.tracking.reset()
        self.kalman.clear()
        self.ema.clear()
        self._tracker_error = None
        return True

    def _update_diagnostics(self):
        capture_fps = 0.0
        if len(self._capture_times) > 1:
            elapsed = self._capture_times[-1] - self._capture_times[0]
            if elapsed > 0:
                capture_fps = (len(self._capture_times) - 1) / elapsed
        processing_fps = (
            1.0 / (sum(self._processing_times) / len(self._processing_times))
            if self._processing_times and sum(self._processing_times) > 0 else 0.0
        )
        self.ui.update_diagnostics({
            "camera": (
                f"connected {self._cam_idx} {self._current_res[0]}x{self._current_res[1]}"
                if self._camera_connected
                else f"disconnected {self._cam_idx}"
            ),
            "capture_fps": capture_fps,
            "processing_fps": processing_fps,
            "detections": self._last_detection_count,
            "tracker": self.tracker.name,
            "udp": "sent (unconfirmed)" if self._last_udp_ok else "waiting" if self._last_udp_ok is None else "error",
        })

    # ------------------------------------------------------------------
    # Camera helpers
    # ------------------------------------------------------------------
    def _open_cap(self, idx: int):
        """Open camera at idx and verify a frame can actually be read.
        Returns the cap if working, or a released cap object if not."""
        try:
            cap = cv2.VideoCapture(idx)
        except cv2.error as exc:
            print(f"[Camera] Could not initialize camera {idx}: {exc}")
            return cv2.VideoCapture()
        if not cap.isOpened():
            cap.release()
            return cv2.VideoCapture()
        # MSMF on Windows sometimes reports isOpened()=True but fails to
        # deliver frames (e.g. camera held by another process / IR sensor).
        # Drain up to 5 frames with brief sleeps to confirm the stream works.
        for _ in range(3):
            ok, _ = cap.read()
            if ok:
                self._cam_idx = idx
                return cap
            time.sleep(0.05)
        cap.release()
        return cv2.VideoCapture()

    def _auto_open_cap(self):
        """Scan indices 0-9 and return the first camera that delivers frames."""
        for idx in range(10):
            cap = self._open_cap(idx)
            if cap.isOpened():
                print(f"Camera {idx} opened successfully.")
                return cap
        return cv2.VideoCapture()

    def _try_switch_camera(self, index):
        candidate = self._open_cap(index)
        if candidate.isOpened():
            return candidate
        candidate.release()
        return None

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------
    def run(self):
        cap = self._auto_open_cap()
        self._camera_connected = cap.isOpened()
        if not cap.isOpened():
            print("WARNING: No camera found. Retrying while the control panel remains open.")

        def _on_click(x: int, y: int):
            if self.calibration.state == Calibration.SELECTING:
                frame_size = self._current_res
                self.calibration.add_point(x, y, frame_size)
                print(f"[Calibration] {self.calibration.message}")

        self.ui.set_click_callback(_on_click)

        # Start phone web remote
        self._remote.start()
        print(f"\nWeb remote: {self._remote.get_url()}  (PIN in remote_config.json)")

        print("\nLightTable CV ready.")
        print("  Esc / q    quit")
        print("  c          reset calibration")
        print("  a          freeze & select object  (Object tracker only)")
        print("  x          clear tracked objects   (Object tracker only)\n")

        frame_deadline = time.monotonic()
        next_camera_retry = time.monotonic()
        next_selected_camera_retry = time.monotonic()
        settings = self.ui.read()

        while self.ui.is_open():
            settings = self.ui.read()

            # ---- Tracker switch ----
            new_tidx = settings["Tracker"]
            if new_tidx != self._tracker_idx:
                self._switch_tracker(new_tidx, settings.get("Pointers", True))

            # ---- Keyboard shortcuts (1-6 for trackers) ----
            for k in self.ui._pending_keys:
                if k in "123456":
                    new_idx = int(k) - 1
                    self.ui._tracker_var.set(TRACKER_NAMES[new_idx])
            self.ui._pending_keys.clear()

            # ---- Camera switch ----
            new_cidx = settings["Camera Idx"]
            if new_cidx != self._cam_idx and time.monotonic() >= next_selected_camera_retry:
                new_cap = self._try_switch_camera(new_cidx)
                if new_cap is not None:
                    cap.release()
                    cap = new_cap
                    self._camera_connected = True
                    self.tracker.reset()
                    self.tracking.reset()
                else:
                    print(f"[Camera] Camera {new_cidx} unavailable; keeping camera {self._cam_idx}")
                    next_selected_camera_retry = time.monotonic() + 2.0

            # ---- Resolution change ----
            # We resize in software after capture instead of asking the camera
            # driver to change modes (MSMF on Windows often ignores CAP_PROP
            # requests and just crops the ROI instead of downscaling).
            new_res = settings["Resolution"]
            if new_res != self._current_res:
                self._current_res = new_res

            # ---- Remote tracker change (phone web remote) ----
            remote_tidx = self._ctrl_state.pop_tracker_request()
            if remote_tidx is not None and remote_tidx != self._tracker_idx:
                self._switch_tracker(remote_tidx, settings.get("Pointers", True))

            if not cap.isOpened():
                now = time.monotonic()
                if now >= next_camera_retry:
                    replacement = self._open_cap(self._cam_idx)
                    if replacement.isOpened():
                        cap = replacement
                        self._camera_connected = True
                        self.tracker.reset()
                        self.tracking.reset()
                        print(f"[Camera] Camera {self._cam_idx} reconnected.")
                    else:
                        replacement.release()
                    next_camera_retry = now + 2.0
                self._ctrl_state.update_status(
                    audio=0.0, tracker_idx=self._tracker_idx,
                    detections=self._last_detection_count,
                    camera="disconnected", calibration=self.calibration.state,
                )
                self._update_diagnostics()
                keys = self.ui.tick()
                if "esc" in keys or "q" in keys:
                    break
                time.sleep(0.05)
                continue

            ok, frame = cap.read()
            if not ok:
                print(f"[Camera] Lost frame from camera {self._cam_idx}; retrying.")
                self._camera_connected = False
                self.frame_motion.reset()
                self._send({"type": "frame_motion", "amount": 0.0, "points": []})
                for event in self.interactions.close_all(time.monotonic()):
                    self._send_event(event, settings.get("Pointers", True))
                self.tracking.reset()
                self.ema.clear()
                self.kalman.clear()
                cap.release()
                cap = cv2.VideoCapture()
                next_camera_retry = time.monotonic() + 0.25
                continue
            now = time.monotonic()
            self._camera_connected = True
            self._capture_times.append(now)
            source_size = (frame.shape[1], frame.shape[0])
            self._set_calibration_context(source_size, settings)
            frame_duration = 1.0 / max(1, settings["Target FPS"])
            sleep_for = frame_deadline - now
            if sleep_for > 0:
                time.sleep(sleep_for)
            frame_deadline = max(time.monotonic(), frame_deadline + frame_duration)
            frame   = self._adjust_frame(frame, settings)
            display = self.process_frame(frame, settings, time.monotonic())

            # Update status for web remote
            self._ctrl_state.update_status(
                audio       = 0.0,   # audio is Godot-side; CV doesn't measure it
                tracker_idx = self._tracker_idx,
                detections  = getattr(self, "_last_detection_count", 0),
                camera=f"{self._cam_idx} {source_size[0]}x{source_size[1]}",
                calibration=self.calibration.state,
            )

            # Push to unified Tkinter preview (no-op when hidden)
            self.ui.update_preview(display)
            self._update_diagnostics()

            # Drive Tkinter event loop; collect keypresses
            keys = self.ui.tick()

            if "esc" in keys or "q" in keys:
                break
            if "c" in keys:
                self.calibration.reset()
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
        if hasattr(self.tracker, "close"):
            self.tracker.close()
        self.bridge.close()
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
                self._send({
                    "type": "interaction",
                    "id": 0,
                    "x": float(0.5 + 0.3 * np.sin(t)),
                    "y": float(0.5 + 0.3 * np.cos(t)),
                    "state": "move",
                    "event": "move",
                    "tracker": "Simulation",
                    "timestamp": time.monotonic(),
                })
                time.sleep(0.016)
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    LightTableCV().run()
