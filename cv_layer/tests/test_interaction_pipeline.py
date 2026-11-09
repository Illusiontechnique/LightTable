import tempfile
import unittest
from collections import deque
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import cv2
import numpy as np

from calibration import Calibration
from frame_motion import FrameMotion
from main import LightTableCV
from smoothing import ExponentialSmoother, KalmanSmoother
from tracking import InteractionEventGenerator, TrackingManager


class InteractionPipelineTests(unittest.TestCase):
    def test_tracker_and_frame_motion_use_separate_calibrated_packets(self):
        app = object.__new__(LightTableCV)
        with tempfile.TemporaryDirectory() as directory:
            app.calibration = Calibration(Path(directory) / "calibration.json")
            app.calibration.state = Calibration.CALIBRATED
            app.calibration.points = [[0, 0], [319, 0], [319, 239], [0, 239]]
            app.calibration.matrix = np.array([[6, 0, 0], [0, 4.5, 0], [0, 0, 1]], dtype=np.float64)
            app.tracker = SimpleNamespace(
                name="Synthetic",
                process=Mock(return_value=[{"x": 80, "y": 120}]),
                draw_debug=lambda frame, detections: frame,
            )
            app._current_res = (320, 240)
            app.tracking = TrackingManager()
            app.interactions = InteractionEventGenerator()
            app.frame_motion = FrameMotion()
            app.ema, app.kalman = ExponentialSmoother(), KalmanSmoother()
            app._tracker_error, app._motion_enabled = None, False
            app._processing_times = deque(maxlen=30)
            app._cam_idx = 0
            app.ui = SimpleNamespace(update_calibration_status=Mock())
            app.bridge = SimpleNamespace(send_motion_frame=Mock())
            app._last_udp_ok = None
            app._send = Mock()
            settings = {"Smoothing": 0, "EMA Respons": 35, "Show Mask": 0,
                        "Frame Motion": True, "Motion Delay ms": 200}
            blank = np.zeros((240, 320, 3), dtype=np.uint8)
            app.process_frame(blank, settings, 1.0)
            frame = blank.copy()
            cv2.rectangle(frame, (60, 60), (160, 160), (255, 255, 255), -1)
            app.process_frame(frame, settings, 1.1)
            self.assertEqual(app._send.call_args.args[0]["amount"], 0.0)
            app.process_frame(frame, settings, 1.2)
            settings["Preview Mode"] = "Motion (projected)"
            projected_preview = app.process_frame(frame, settings, 1.25)
            self.assertEqual(projected_preview.shape, (180, 320, 3))
            self.assertGreater(int(projected_preview[50:150, 40:200].max()), 0)
            settings["Preview Mode"] = "Motion (camera)"
            camera_preview = app.process_frame(frame, settings, 1.26)
            self.assertEqual(camera_preview.shape, (240, 320, 3))
            self.assertGreater(int(camera_preview[50:180, 40:180].max()), 0)
            packets = [call.args[0] for call in app._send.call_args_list]
            interaction = next(p for p in packets if p["type"] == "interaction")
            motion = [p for p in packets if p["type"] == "frame_motion"][-1]
            self.assertAlmostEqual(interaction["x"], 0.25)
            self.assertAlmostEqual(interaction["y"], 0.5)
            self.assertGreater(motion["amount"], 0.1)
            self.assertGreater(len(motion["points"]), 1)
            self.assertTrue(all(0 <= p["x"] <= 1 and 0 <= p["y"] <= 1
                                for p in motion["points"]))
            self.assertEqual(len(app.bridge.send_motion_frame.call_args.args[0]), 19200)


if __name__ == "__main__":
    unittest.main()
