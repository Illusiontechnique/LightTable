import json
import tempfile
import unittest
from pathlib import Path

from calibration import Calibration


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.path = Path(self.temp_dir.name) / "calibration.json"
        self.signature = Calibration.make_signature(0, (1280, 720), (640, 480), False)
        self.points = [(50, 40), (590, 40), (590, 440), (50, 440)]

    def tearDown(self):
        self.temp_dir.cleanup()

    def calibrated(self, path=None, signature=None):
        calibration = Calibration(path or self.path)
        calibration.set_context(signature or self.signature)
        calibration.start()
        for point in self.points:
            calibration.add_point(*point, frame_size=(640, 480))
        return calibration

    def test_valid_geometry_and_transform(self):
        calibration = self.calibrated()
        self.assertEqual(calibration.state, Calibration.CALIBRATED)
        x, y = calibration.apply(50, 40)
        self.assertAlmostEqual(x, 0, delta=0.1)
        self.assertAlmostEqual(y, 0, delta=0.1)
        x, y = calibration.apply(590, 440)
        self.assertAlmostEqual(x, 1919, delta=0.1)
        self.assertAlmostEqual(y, 1079, delta=0.1)

    def test_invalid_order_and_degenerate_region_are_rejected(self):
        valid, _ = Calibration.validate_points(
            [(590, 40), (50, 40), (590, 440), (50, 440)], (640, 480)
        )
        self.assertFalse(valid)
        valid, _ = Calibration.validate_points(
            [(50, 40), (590, 440), (590, 40), (50, 440)], (640, 480)
        )
        self.assertFalse(valid)

    def test_undo_reset_and_cancel_restore_previous_calibration(self):
        calibration = self.calibrated()
        previous = calibration.matrix.copy()
        calibration.start()
        calibration.add_point(50, 40, (640, 480))
        calibration.add_point(590, 40, (640, 480))
        self.assertTrue(calibration.undo())
        self.assertEqual(len(calibration.points), 1)
        calibration.start()
        calibration.cancel()
        self.assertEqual(calibration.state, Calibration.CALIBRATED)
        self.assertEqual(calibration.matrix.tolist(), previous.tolist())
        calibration.cancel()
        self.assertEqual(calibration.state, Calibration.CALIBRATED)
        calibration.reset()
        self.assertIsNone(calibration.matrix)
        self.assertEqual(calibration.points, [])

    def test_save_auto_load_and_incompatible_profile_is_not_applied(self):
        calibration = self.calibrated()
        calibration.save()
        reloaded = Calibration(self.path)
        self.assertTrue(reloaded.set_context(self.signature))
        self.assertEqual(reloaded.state, Calibration.CALIBRATED)
        self.assertEqual(reloaded.points, [list(point) for point in self.points])
        reloaded.reset()
        self.assertTrue(reloaded.load_profile())
        self.assertEqual(reloaded.state, Calibration.CALIBRATED)

        incompatible = Calibration.make_signature(0, (1280, 720), (640, 480), True)
        self.assertFalse(reloaded.set_context(incompatible))
        self.assertIsNone(reloaded.matrix)
        self.assertEqual(reloaded.state, Calibration.ERROR)

    def test_invalid_and_legacy_calibrations_are_never_loaded_or_saved(self):
        self.path.write_text(json.dumps({"matrix": [[1, 0, 0], [0, 1, 0], [0, 0, 1]]}))
        calibration = Calibration(self.path)
        self.assertFalse(calibration.set_context(self.signature))
        self.assertIsNone(calibration.matrix)
        with self.assertRaises(ValueError):
            calibration.save()

        calibration = Calibration(Path(self.temp_dir.name) / "new.json")
        calibration.set_context(self.signature)
        calibration.start()
        for point in [(50, 40), (590, 440), (590, 40), (50, 440)]:
            calibration.add_point(*point, frame_size=(640, 480))
        self.assertEqual(calibration.state, Calibration.ERROR)
        self.assertIsNone(calibration.matrix)

    def test_malformed_calibration_document_reports_error_instead_of_defaulting(self):
        self.path.write_text("[1, 2]")
        calibration = Calibration(self.path)
        calibration.set_context(self.signature)
        self.assertEqual(calibration.state, Calibration.ERROR)
        self.assertIn("could not be read", calibration.message)


if __name__ == "__main__":
    unittest.main()
