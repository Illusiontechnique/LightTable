import json
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import cv2
import numpy as np

from calibration import Calibration
from control_window import ControlWindow, SMOOTH_LABELS
from environment_presets import EnvironmentPresets
from main import LightTableCV
from operator_preview import OperatorPreview
from web_remote import ControlState, WebRemote


class OperatorTests(unittest.TestCase):
    def setUp(self):
        self.state = ControlState()
        self.remote = WebRemote(self.state)
        self.remote._cfg["pin"] = "246810"
        self.app = self.remote._create_app()
        self.app.testing = True
        self.client = self.app.test_client()
        self.client.post("/login", json={"pin": "246810"})
        self.signature = Calibration.make_signature(0, (640, 480), (320, 240), False)
        self.snapshot = {
            "settings": {
                "camera": {"value": 0, "min": 0, "max": 9},
                "tracker": {"value": "Edge", "options": ["Hands", "Edge"]},
                "motion": {"value": True, "type": "boolean"},
            },
            "tracker_settings": {"Canny Low": {"value": 50, "min": 0, "max": 255}},
            "tracker_name": "Edge / Canny",
            "tracker_ready": True,
            "calibration": {"state": "selecting", "message": "Select", "points": [],
                            "signature": self.signature, "resolution": [320, 240],
                            "context": Calibration._profile_key(self.signature), "camera_connected": True},
        }
        self.state.publish_operator(self.snapshot)

    def tearDown(self):
        self.state.preview.close()

    def test_operator_endpoints_require_login(self):
        client = self.app.test_client()
        self.assertEqual(client.get("/preview/camera").status_code, 401)
        self.assertEqual(client.get("/operator").status_code, 401)
        self.assertEqual(client.post("/operator/settings", json={}).status_code, 401)
        self.assertEqual(client.get("/operator/presets").status_code, 401)
        self.assertEqual(client.post("/operator/object", json={"action": "clear"}).status_code, 401)

    def test_operator_navigation_and_preview_are_grouped_under_settings(self):
        html = self.client.get("/").get_data(as_text=True)
        main_nav = html.split('<nav class="tabs" aria-label="Main navigation">', 1)[1].split("</nav>", 1)[0]
        settings_nav = html.split('<nav id="settingsNav"', 1)[1].split("</nav>", 1)[0]
        tracking = html.split('<section id="page-tracking"', 1)[1].split("</section>", 1)[0]
        diagnostics = html.split('<section id="page-diagnostics"', 1)[1].split("</section>", 1)[0]
        self.assertIn("Play", main_nav)
        self.assertIn("Settings", main_nav)
        for section in ("Tracking", "Calibration", "Diagnostics", "Preferences"):
            self.assertIn(section, settings_nav)
        self.assertIn('id="trackerSelect"', tracking)
        self.assertIn('id="trackerControls"', tracking)
        self.assertIn('id="trackingPreview"', tracking)
        self.assertNotIn("<img", diagnostics)
        self.assertIn('id="micStatus"', diagnostics)

    def test_tracker_selector_queues_shared_setting(self):
        response = self.client.post("/operator/settings", json={
            "settings": {"tracker": "Hands"}, "tracker_settings": {}, "tracker_name": "Edge / Canny",
        })
        self.assertEqual(response.status_code, 200)
        command = self.state.pop_operator_commands()[0]
        self.assertEqual(command["settings"], {"tracker": "Hands"})
        self.assertEqual(command["tracker_settings"], {})

    def test_operator_serializes_compatible_calibration_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            calibration = Calibration(Path(directory) / "calibration.json")
            calibration.set_context(self.signature)
            calibration.start()
            for point in [(20, 20), (300, 20), (300, 220), (20, 220)]:
                calibration.add_point(*point, frame_size=(320, 240))
            calibration.save()
            self.snapshot["calibration"]["profiles"] = calibration.list_profiles()
            self.state.publish_operator(self.snapshot)

            response = self.client.get("/operator")
            self.assertEqual(response.status_code, 200)
            self.assertIs(response.get_json()["calibration"]["profiles"][0]["compatible"], True)

    def test_object_region_requires_current_camera_and_tracker(self):
        self.assertEqual(self.client.post("/operator/object", json={"action": "clear"}).status_code, 409)
        self.snapshot["tracker_name"] = "Object Tracking (CSRT)"
        region = {"action": "add", "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4,
                  "context": self.snapshot["calibration"]["context"]}
        self.assertEqual(self.client.post("/operator/object", json={**region, "context": "stale"}).status_code, 409)
        self.assertEqual(self.client.post("/operator/object", json={**region, "width": 1.0}).status_code, 400)
        self.assertEqual(self.client.post("/operator/object", json=region).status_code, 200)
        command = self.state.pop_operator_commands()[0]
        self.assertEqual(command["signature"], self.signature)

    def test_settings_validate_and_queue_for_main_thread(self):
        response = self.client.post("/operator/settings", json={
            "settings": {"camera": 3},
            "tracker_settings": {"Canny Low": 100}, "tracker_name": "Edge / Canny",
        })
        self.assertEqual(response.status_code, 200)
        command = self.state.pop_operator_commands()[0]
        self.assertEqual(command["settings"]["camera"], 3)
        self.assertEqual(command["tracker_settings"]["Canny Low"], 100)
        self.assertEqual(self.client.post("/operator/settings", json={
            "settings": {"camera": 99}}).status_code, 400)
        self.assertEqual(self.client.post("/operator/settings", json={
            "tracker_settings": {"Canny Low": 42}, "tracker_name": "old"}).status_code, 409)

    def test_remote_settings_use_desktop_variables_and_processing(self):
        class Variable:
            def __init__(self, value):
                self.value = value
            def get(self):
                return self.value
            def set(self, value):
                self.value = value

        ui = object.__new__(ControlWindow)
        defaults = {
            "_camera_var": 0, "_bright_var": 50, "_contrast_var": 50, "_ema_var": 35,
            "_fps_var": 30, "_motion_threshold_var": 25, "_motion_min_var": 1,
            "_motion_delay_var": 50, "_fliph_var": False, "_motion_var": True,
            "_pointers_var": True, "_showmask_var": False, "_res_var": "320 × 240",
            "_smooth_var": SMOOTH_LABELS[0], "_tracker_var": "Edge", "_preview_mode_var": "Camera",
        }
        for name, value in defaults.items():
            setattr(ui, name, Variable(value))
        ui._tracker_vars = {"Canny Low": Variable(50)}
        ui._save_settings = Mock()
        tracker = SimpleNamespace(name="Edge / Canny", get_trackbar_settings=lambda: [
            {"name": "Canny Low", "max": 255, "default": 50}])
        ui.apply_operator_settings({"brightness": 70}, {"Canny Low": 80})
        settings = ui.read()
        self.assertEqual(settings["Brightness"], 70)
        self.assertEqual(ui.operator_settings(tracker)["tracker_settings"]["Canny Low"]["value"], 80)
        app = object.__new__(LightTableCV)
        app._current_res = (320, 240)
        output = app._adjust_frame(np.zeros((240, 320, 3), np.uint8), settings)
        self.assertEqual(int(output[0, 0, 0]), 20)
        ui._bright_var.set(60)
        self.assertEqual(ui.operator_settings(tracker)["settings"]["brightness"]["value"], 60)

    def test_calibration_click_maps_normalized_coordinates_in_main_thread(self):
        response = self.client.post("/operator/calibration", json={
            "action": "point", "x": 0.25, "y": 0.5, "context": self.snapshot["calibration"]["context"]})
        self.assertEqual(response.status_code, 200)
        app = object.__new__(LightTableCV)
        app._ctrl_state = self.state
        app.calibration = Calibration()
        app.calibration.signature = self.signature
        app.calibration.state = Calibration.SELECTING
        app._current_res = (320, 240)
        app._operator_message = ""
        app._camera_connected = True
        app._last_udp_ok = None
        app._tracker_idx = 4
        app.tracker = SimpleNamespace(name="Edge / Canny")
        app.settings = SimpleNamespace(operator_settings=Mock(return_value={
            "settings": {"tracker": {"value": "Edge"}}, "tracker_settings": {},
            "tracker_name": app.tracker.name}))
        app.ui = None
        app._capture_times, app._processing_times = [], []
        app._operator_tick()
        self.assertEqual(app.calibration.points, [[80, 120]])
        self.assertEqual(self.client.post("/operator/calibration", json={
            "action": "point", "x": 1.0, "y": 0.5, "context": self.snapshot["calibration"]["context"]}).status_code, 400)
        self.assertEqual(self.client.post("/operator/calibration", json={
            "action": "point", "x": 0.5, "y": 0.5, "context": "stale"}).status_code, 409)

    def test_audio_telemetry_not_overwritten_by_camera_status(self):
        self.state.update_godot_status({"audio_raw": 0.12, "audio_level": 0.6,
                                        "audio_floor": 0.02, "audio_ceil": 0.2,
                                        "audio_status": "active"})
        self.state.update_status(audio=0, tracker_idx=0, detections=0)
        data = self.client.get("/status").get_json()
        self.assertEqual(data["audio_raw"], 0.12)
        self.assertEqual(data["audio_level"], 0.6)
        self.assertTrue(data["audio_fresh"])
        with patch.object(self.remote, "_send_godot") as send:
            result = self.client.post("/audio", json={"floor": 0.04, "ceil": 0.4})
        self.assertEqual(result.status_code, 200)
        self.assertEqual(send.call_args.args[0]["floor"], 0.04)
        self.assertEqual(self.client.get("/status").get_json()["audio_floor"], 0.02)

    def test_presets_save_rename_load_delete_and_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "presets.json"
            self.remote._presets = EnvironmentPresets(path)
            self.state.update_godot_status({"audio_floor": 0.03, "audio_ceil": 0.3,
                                            "audio_status": "active"})
            save = self.client.post("/operator/presets", json={"action": "save", "name": "Room"})
            self.assertEqual(save.status_code, 200)
            stored = EnvironmentPresets(path).get("Room")
            self.assertEqual(stored["audio_floor"], 0.03)
            self.assertEqual(stored["tracker_settings"]["Canny Low"], 50)
            self.assertEqual(stored["calibration_signature"], self.signature)
            self.assertEqual(self.client.post("/operator/presets", json={
                "action": "rename", "name": "Room", "new_name": "Dim"}).status_code, 200)
            self.assertEqual(self.client.post("/operator/presets", json={
                "action": "load", "name": "Dim"}).status_code, 200)
            self.assertEqual(self.state.pop_operator_commands()[0]["preset"]["audio_ceil"], 0.3)
            self.assertEqual(self.client.post("/operator/presets", json={
                "action": "delete", "name": "Dim"}).status_code, 200)
            self.assertEqual(EnvironmentPresets(path).list(), [])

    def test_preset_reaches_desktop_settings_and_godot(self):
        preset = {
            "settings": {"tracker": "Edge", "camera": 2},
            "tracker_name": "Edge / Canny",
            "tracker_settings": {"Canny Low": 80},
            "audio_floor": 0.02, "audio_ceil": 0.3,
        }
        self.assertTrue(self.state.queue_operator({"type": "preset", "preset": preset}))
        app = object.__new__(LightTableCV)
        app._ctrl_state = self.state
        app._tracker_idx = 4
        app.tracker = SimpleNamespace(name="Edge / Canny")
        app.settings = SimpleNamespace(
            operator_settings=Mock(return_value=self.snapshot),
            apply_operator_settings=Mock(),
        )
        app.ui = None
        app._remote = SimpleNamespace(_send_godot=Mock())
        app.calibration = Calibration()
        app._current_res = (320, 240)
        app._camera_connected = True
        app._last_udp_ok = None
        app._operator_message = ""
        app._capture_times = []
        app._processing_times = []
        app._operator_tick()
        app.settings.apply_operator_settings.assert_called_once_with(
            preset["settings"], preset["tracker_settings"])
        self.assertEqual(app._remote._send_godot.call_args.args[0]["floor"], 0.02)

    def test_preview_is_shared_demand_driven_and_authenticated(self):
        preview = self.state.preview
        image = np.full((480, 640, 3), 127, np.uint8)
        with patch("operator_preview.cv2.imencode", wraps=cv2.imencode) as encode:
            preview.submit({"camera": image})
            self.assertIsNone(preview._thread)
            self.assertEqual(self.client.get("/preview/camera").status_code, 503)
            preview.submit({"camera": image})
            for _ in range(100):
                result = self.client.get("/preview/camera")
                if result.status_code == 200:
                    break
                time.sleep(0.01)
            self.assertEqual(result.status_code, 200)
            second_client = self.app.test_client()
            second_client.post("/login", json={"pin": "246810"})
            second = second_client.get("/preview/camera")
            self.assertEqual(second.data, result.data)
            self.assertEqual(encode.call_count, 1)
            decoded = cv2.imdecode(np.frombuffer(result.data, np.uint8), cv2.IMREAD_COLOR)
            self.assertEqual(decoded.shape[:2], (240, 320))
            with preview._condition:
                preview._leases["camera"] = 0
            preview.submit({"camera": image})
            time.sleep(0.05)
            self.assertEqual(encode.call_count, 1)


if __name__ == "__main__":
    unittest.main()
