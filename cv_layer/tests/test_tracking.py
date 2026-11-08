import unittest

from tracking import InteractionEventGenerator, TrackingManager
from smoothing import KalmanSmoother


class TrackingTests(unittest.TestCase):
    def test_kalman_initializes_from_measurement_and_uses_elapsed_time(self):
        smoother = KalmanSmoother()
        self.assertEqual(smoother.smooth(1, 25, 30, 2.0), (25, 30))
        smoother.smooth(1, 30, 30, 2.1)
        self.assertAlmostEqual(
            float(smoother._filters[1].transitionMatrix[0, 2]), 0.1, places=5
        )

    def test_ids_persist_when_detection_order_changes(self):
        manager = TrackingManager(max_distance=30, stale_after=0.5)
        first, _ = manager.update(
            [{"id": 0, "x": 10, "y": 10}, {"id": 1, "x": 100, "y": 10}], 1.0
        )
        first_ids = {round(item["x"]): item["id"] for item in first}
        second, _ = manager.update(
            [{"id": 0, "x": 102, "y": 10}, {"id": 1, "x": 12, "y": 10}], 1.1
        )
        second_ids = {round(item["x"]): item["id"] for item in second}
        self.assertEqual(second_ids[12], first_ids[10])
        self.assertEqual(second_ids[102], first_ids[100])

    def test_stale_tracking_histories_expire(self):
        manager = TrackingManager(stale_after=0.5)
        tracked, _ = manager.update([{"x": 20, "y": 30}], 0.0)
        expired_detection, expired_ids = manager.update([], 0.6)
        self.assertEqual(expired_detection, [])
        self.assertEqual(expired_ids, [tracked[0]["id"]])
        next_detection, _ = manager.update([{"x": 20, "y": 30}], 0.7)
        self.assertNotEqual(next_detection[0]["id"], tracked[0]["id"])

    def test_events_include_lifecycle_dwell_swipe_velocity_and_expiry(self):
        events = InteractionEventGenerator(lost_after=0.5, dwell_after=0.5)
        self.assertEqual(events.update(
            [{"id": 7, "x": 0.1, "y": 0.2, "tracker": "Hands"}], 0.0
        )[0]["event"], "enter")
        movement = events.update(
            [{"id": 7, "x": 0.4, "y": 0.2, "tracker": "Hands",
              "velocity": (0.6, 0.0)}], 0.2
        )
        self.assertEqual([event["event"] for event in movement], ["move", "swipe"])
        self.assertIn("velocity", movement[0])
        self.assertAlmostEqual(movement[1]["direction"]["x"], 1.0)
        dwell = events.update(
            [{"id": 7, "x": 0.4, "y": 0.2, "tracker": "Hands"}], 0.6
        )
        self.assertIn("dwell", [event["event"] for event in dwell])
        exit_events = events.update([], 1.2)
        self.assertEqual(exit_events[0]["event"], "exit")

    def test_event_contract_has_stable_id_normalized_position_and_method(self):
        generator = InteractionEventGenerator()
        event = generator.update(
            [{"id": 3, "x": 0.25, "y": 0.75, "tracker": "Blob"}], 10.0
        )[0]
        self.assertEqual(
            {key: event[key] for key in ("type", "id", "x", "y", "state", "event", "tracker")},
            {"type": "interaction", "id": 3, "x": 0.25, "y": 0.75,
             "state": "enter", "event": "enter", "tracker": "Blob"},
        )
        self.assertEqual(event["timestamp"], 10.0)


if __name__ == "__main__":
    unittest.main()
