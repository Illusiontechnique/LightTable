import unittest

import cv2
import numpy as np

from frame_motion import FrameMotion


class FrameMotionTests(unittest.TestCase):
    def setUp(self):
        self.motion = FrameMotion()
        self.blank = np.zeros((240, 320, 3), dtype=np.uint8)

    def test_motion_edges_amount_throttle_and_stop(self):
        self.assertEqual(self.motion.update(self.blank, 0), {"amount": 0.0, "points": []})
        frame = self.blank.copy()
        cv2.rectangle(frame, (60, 60), (160, 160), (255, 255, 255), -1)
        self.assertIsNone(self.motion.update(frame, 0.02))
        result = self.motion.update(frame, 0.1)
        self.assertGreater(result["amount"], 0.1)
        self.assertLessEqual(len(result["points"]), 8)
        self.assertGreater(len(result["points"]), 1)
        self.assertTrue(all(0 <= x < 320 and 0 <= y < 240 for x, y in result["points"]))
        self.assertEqual(self.motion.update(frame, 0.2), {"amount": 0.0, "points": []})

    def test_calibrated_region_excludes_outside_motion(self):
        region = [(0, 0), (150, 0), (150, 239), (0, 239)]
        self.motion.update(self.blank, 0, region=region)
        frame = self.blank.copy()
        cv2.rectangle(frame, (200, 30), (280, 180), (255, 255, 255), -1)
        self.assertEqual(self.motion.update(frame, 0.1, region=region),
                         {"amount": 0.0, "points": []})

    def test_reset_and_minimum_area_suppress_false_motion(self):
        self.motion.update(self.blank, 0)
        frame = self.blank.copy()
        cv2.rectangle(frame, (60, 60), (90, 90), (255, 255, 255), -1)
        self.assertEqual(self.motion.update(frame, 0.1, min_percent=10),
                         {"amount": 0.0, "points": []})
        self.motion.reset()
        self.assertEqual(self.motion.update(self.blank, 0.2), {"amount": 0.0, "points": []})

    def test_motion_frame_has_intensity_and_projection_alignment(self):
        self.motion.update(self.blank, 0)
        frame = self.blank.copy()
        cv2.rectangle(frame, (60, 60), (100, 100), (255, 255, 255), -1)
        self.motion.update(frame, 0.1)
        raw = np.frombuffer(self.motion.projection_frame((320, 240)), dtype=np.uint8).reshape(120, 160)
        matrix = np.array([[2, 0, 320], [0, 2, 0], [0, 0, 1]], dtype=np.float64)
        warped = np.frombuffer(
            self.motion.projection_frame((320, 240), matrix, (640, 480)), dtype=np.uint8
        ).reshape(120, 160)
        self.assertEqual(raw.size, 19200)
        self.assertGreater(raw[40, 40], 0)
        self.assertGreater(warped[40, 120], 0)
        self.assertEqual(warped[40, 40], 0)

    def test_comparison_delay_uses_older_frame_without_changing_send_rate(self):
        frame = self.blank.copy()
        cv2.rectangle(frame, (60, 60), (160, 160), (255, 255, 255), -1)
        self.motion.update(self.blank, 0.0, comparison_delay_ms=200)
        self.assertEqual(self.motion.update(frame, 0.1, comparison_delay_ms=200)["amount"], 0.0)
        self.assertGreater(self.motion.update(frame, 0.2, comparison_delay_ms=200)["amount"], 0.1)
        self.assertEqual(self.motion.update(frame, 0.3, comparison_delay_ms=200)["amount"], 0.0)

    def test_delay_changes_use_retained_history_and_reset_discards_it(self):
        frame = self.blank.copy()
        cv2.rectangle(frame, (60, 60), (160, 160), (255, 255, 255), -1)
        self.motion.update(self.blank, 0.0)
        self.motion.update(frame, 0.1)
        self.assertEqual(self.motion.update(frame, 0.2)["amount"], 0.0)
        self.assertGreater(self.motion.update(frame, 0.3, comparison_delay_ms=300)["amount"], 0.1)
        self.motion.reset()
        self.assertEqual(self.motion.update(frame, 0.4, comparison_delay_ms=300)["amount"], 0.0)

    def test_history_is_bounded_and_uses_actual_sample_times(self):
        for i in range(100):
            self.motion.update(self.blank, i * 0.1, comparison_delay_ms=1000)
        self.assertLessEqual(len(self.motion.history), 12)
        self.assertGreaterEqual(9.9 - self.motion.history[0][0], 1.0)


if __name__ == "__main__":
    unittest.main()
