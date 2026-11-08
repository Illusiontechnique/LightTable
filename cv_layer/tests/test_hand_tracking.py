import unittest
from types import SimpleNamespace

from trackers.hand_tracker import HandTracker


def _landmark(x, y, z=0.0):
    return SimpleNamespace(x=x, y=y, z=z)


def make_hand(index_extended=True, others_extended=False):
    points = [_landmark(0.5, 0.8) for _ in range(21)]
    points[0] = _landmark(0.5, 0.8)
    fingers = ((5, 6, 8, 0.40), (9, 10, 12, 0.47),
               (13, 14, 16, 0.54), (17, 18, 20, 0.61))
    for mcp, pip, tip, x in fingers:
        extended = index_extended if mcp == 5 else others_extended
        points[mcp] = _landmark(x, 0.60)
        points[pip] = _landmark(x, 0.48)
        points[tip] = _landmark(x, 0.30) if extended else _landmark(x + 0.06, 0.52)
    points[7] = _landmark(0.40, 0.37) if index_extended else _landmark(0.42, 0.49)
    points[11] = _landmark(0.47, 0.37) if others_extended else _landmark(0.49, 0.49)
    points[15] = _landmark(0.54, 0.37) if others_extended else _landmark(0.56, 0.49)
    points[19] = _landmark(0.61, 0.37) if others_extended else _landmark(0.63, 0.49)
    return SimpleNamespace(landmark=points)


def make_tracker(target_mode=1):
    tracker = object.__new__(HandTracker)
    tracker._target_mode = target_mode
    tracker._pose_by_hand = {}
    tracker._pose_candidate = {}
    tracker._pose_candidate_frames = {}
    return tracker


class HandTrackingTests(unittest.TestCase):
    def test_isolated_index_extension_is_detected_without_image_up_heuristic(self):
        hand = make_hand(index_extended=True, others_extended=False)
        self.assertEqual(HandTracker.classify_pose(hand), "pointing")

    def test_open_hand_stays_in_general_hand_mode(self):
        hand = make_hand(index_extended=True, others_extended=True)
        self.assertEqual(HandTracker.classify_pose(hand), "hand")

    def test_auto_target_uses_palm_then_switches_to_index_after_stable_point(self):
        tracker = make_tracker()
        hand = make_hand(index_extended=True, others_extended=False)
        first = tracker._target_for_hand(0, hand, 640, 480)
        second = tracker._target_for_hand(0, hand, 640, 480)
        third = tracker._target_for_hand(0, hand, 640, 480)
        self.assertEqual(first["target"], "palm")
        self.assertEqual(second["target"], "palm")
        self.assertEqual(third["target"], "index")
        self.assertEqual(third["gesture"], "pointing")
        self.assertEqual(third["x"], hand.landmark[8].x * 640)

    def test_target_mode_can_force_palm_or_index(self):
        hand = make_hand(index_extended=True, others_extended=False)
        palm = make_tracker(target_mode=0)._target_for_hand(0, hand, 640, 480)
        index = make_tracker(target_mode=2)._target_for_hand(0, hand, 640, 480)
        self.assertEqual(palm["target"], "palm")
        self.assertEqual(index["target"], "index")


if __name__ == "__main__":
    unittest.main()
