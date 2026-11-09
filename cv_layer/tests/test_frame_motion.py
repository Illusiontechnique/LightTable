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
        self.assertIsNone(self.motion.update(frame, 0.05))
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


if __name__ == "__main__":
    unittest.main()
