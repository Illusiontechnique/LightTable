import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from web_remote import ControlState, WebRemote, _load_config
from control_window import ControlWindow, _load_settings


class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.state = ControlState()
        self.remote = WebRemote(self.state)
        self.remote._cfg["pin"] = "246810"
        self.app = self.remote._create_app()
        self.app.testing = True
        self.client = self.app.test_client()
        self.client.post("/login", json={"pin": "246810"})

    def test_player_selection_changes_player_without_corrupting_scene_state(self):
        with patch("web_remote._load_profiles", return_value={
            "profiles": [{"id": "p1", "first_name": "A", "last_name": "Player"}]
        }):
            response = self.client.post("/set_player", json={"id": "p1"})
        self.assertEqual(response.status_code, 200)
        status = self.state.get_status()
        self.assertEqual(status["player_id"], "p1")
        self.assertEqual(status["player_name"], "A Player")
        self.assertEqual(status["scene"], "Not confirmed")

    def test_scene_request_is_pending_until_godot_confirms_it(self):
        with patch.object(self.remote, "_send_godot") as send:
            response = self.client.post("/scene", json={"scene": "Water"})
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.get_json()["pending"])
        send.assert_called_once()
        status = self.state.get_status()
        self.assertEqual(status["scene"], "Not confirmed")
        self.assertEqual(status["pending_scene"], "Water")
        self.state.update_godot_status({"scene": "Water", "request_id": status["pending_scene_id"]})
        self.assertEqual(self.state.get_status()["scene"], "Water")
        self.assertIsNone(self.state.get_status()["pending_scene"])

    def test_bad_controls_and_cross_origin_posts_are_rejected(self):
        self.assertEqual(
            self.client.post("/tracker", json={"tracker_idx": 99}).status_code, 400
        )
        self.assertEqual(
            self.client.post("/audio", json={"floor": 0.7, "ceil": 0.4}).status_code, 400
        )
        self.assertEqual(
            self.client.post(
                "/clear_cursors", headers={"Origin": "http://attacker.invalid"}
            ).status_code,
            403,
        )

    def test_invalid_remote_config_uses_a_temporary_non_default_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "remote.json"
            path.write_text("{ broken")
            with patch("web_remote._CFG_PATH", path):
                config = _load_config()
        self.assertTrue(config["generated_pin"])
        self.assertTrue(config["pin"].isdigit())
        self.assertEqual(len(config["pin"]), 6)
        self.assertNotEqual(config["pin"], "1234")

    def test_desktop_settings_loading_sanitizes_invalid_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings.json"
            path.write_text(json.dumps({
                "camera_idx": "not-an-index",
                "tracker_idx": 99,
                "ema_alpha": 0,
                "target_fps": 120,
                "resolution": "unsupported",
                "flip_h": "false",
                "motion_delay_ms": 2000,
            }))
            settings = _load_settings(path)
        self.assertEqual(settings["camera_idx"], 0)
        self.assertEqual(settings["tracker_idx"], 5)
        self.assertEqual(settings["ema_alpha"], 1)
        self.assertEqual(settings["target_fps"], 60)
        self.assertEqual(settings["resolution"], "640 × 480")
        self.assertFalse(settings["flip_h"])
        self.assertEqual(settings["motion_delay_ms"], 1000)


class CameraSwitchTests(unittest.TestCase):
    def test_tracker_dropdown_recognizes_mediapipe_hands(self):
        ui = object.__new__(ControlWindow)
        ui._tracker_frame = SimpleNamespace(winfo_children=lambda: [])
        ui._tracker_vars = {}
        ui._tracker_var = Mock()
        ui.rebuild_for_tracker(SimpleNamespace(
            name="MediaPipe Hands", get_trackbar_settings=lambda: []
        ))
        ui._tracker_var.set.assert_called_once_with("Hands")

    def test_failed_camera_switch_preserves_current_capture(self):
        from main import LightTableCV

        app = object.__new__(LightTableCV)
        failed = SimpleNamespace(isOpened=lambda: False, release=lambda: None)
        with patch.object(app, "_open_cap", return_value=failed):
            self.assertIsNone(app._try_switch_camera(4))

    def test_successful_camera_switch_returns_open_capture(self):
        from main import LightTableCV

        app = object.__new__(LightTableCV)
        opened = SimpleNamespace(isOpened=lambda: True)
        with patch.object(app, "_open_cap", return_value=opened):
            self.assertIs(app._try_switch_camera(2), opened)


if __name__ == "__main__":
    unittest.main()
