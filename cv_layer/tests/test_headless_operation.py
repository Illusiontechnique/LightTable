import http.cookiejar
import json
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch
from unittest.mock import Mock

import numpy as np

from app_settings import AppSettings
from main import LightTableCV


class FakeCapture:
    def __init__(self):
        self.open = True
        self.read_count = 0

    def isOpened(self):
        return self.open

    def read(self):
        self.read_count += 1
        frame = np.zeros((240, 320, 3), dtype=np.uint8)
        frame[40:100, (self.read_count % 100):(self.read_count % 100) + 60] = 220
        return True, frame

    def release(self):
        self.open = False


class HeadlessOperationTests(unittest.TestCase):
    def test_import_core_does_not_import_tkinter(self):
        code = "import main,sys; print('tkinter' in sys.modules)"
        result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.strip(), "False")

    def test_settings_persist_tracker_parameters_and_mode(self):
        from trackers.edge_tracker import EdgeTracker
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings.json"
            settings = AppSettings(path)
            tracker = EdgeTracker()
            settings.rebuild_for_tracker(tracker)
            settings.apply_operator_settings({"brightness": 65, "desktop_next_start": True}, {"Canny Low": 80})
            settings.save(force=True)
            restored = AppSettings(path)
            restored.rebuild_for_tracker(EdgeTracker())
            self.assertEqual(restored.values["brightness"], 65)
            self.assertTrue(restored.values["desktop"])
            self.assertEqual(restored.tracker_values["Canny Low"], 80)

    def test_real_headless_loop_remote_preview_and_shutdown(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = AppSettings(Path(directory) / "settings.json")
            settings.values.update({"tracker_idx": 4, "resolution": "320 × 240"})
            app = LightTableCV(desktop=False, settings=settings)
            app._remote._port = 0
            app._remote._cfg["pin"] = "246810"
            camera = FakeCapture()
            app._open_cap = lambda index: camera
            errors = []

            def run():
                try:
                    app.run()
                except Exception as exc:
                    errors.append(exc)

            with patch.object(app._remote, "_generate_qr"):
                thread = threading.Thread(target=run)
                thread.start()
                try:
                    deadline = time.monotonic() + 10
                    while (app._remote._server is None or app._ctrl_state.operator_snapshot() is None) and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertIsNotNone(app._remote._server)
                    self.assertIsNone(app.ui)
                    url = f"http://127.0.0.1:{app._remote._server.server_port}"
                    client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

                    def post(path, payload):
                        request = urllib.request.Request(url + path, data=json.dumps(payload).encode(),
                                                         headers={"Content-Type": "application/json"}, method="POST")
                        return json.load(client.open(request, timeout=3))

                    self.assertTrue(post("/login", {"pin": "246810"})["ok"])
                    self.assertTrue(post("/operator/settings", {"settings": {"brightness": 64}})["ok"])
                    deadline = time.monotonic() + 5
                    while app.settings.values["brightness"] != 64 and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertEqual(app.settings.values["brightness"], 64)
                    before = camera.read_count
                    with patch.object(app.tracker, "draw_debug", wraps=app.tracker.draw_debug) as draw:
                        time.sleep(0.15)
                        self.assertEqual(draw.call_count, 0)
                        try:
                            client.open(url + "/preview/overlay", timeout=3)
                        except urllib.error.HTTPError as exc:
                            self.assertEqual(exc.code, 503)
                        deadline = time.monotonic() + 3
                        while draw.call_count == 0 and time.monotonic() < deadline:
                            time.sleep(0.03)
                        self.assertGreater(draw.call_count, 0)
                        with app._ctrl_state.preview._condition:
                            app._ctrl_state.preview._leases["overlay"] = 0
                        time.sleep(0.08)
                        count = draw.call_count
                        time.sleep(0.15)
                        self.assertEqual(draw.call_count, count)
                    self.assertGreater(camera.read_count, before)
                    self.assertTrue(post("/operator/lifecycle", {"action": "shutdown", "confirm": True})["ok"])
                    thread.join(timeout=8)
                    self.assertFalse(thread.is_alive(), "remote shutdown did not stop the loop")
                finally:
                    app._stop_requested = True
                    thread.join(timeout=8)
                self.assertFalse(thread.is_alive())
                self.assertFalse(camera.isOpened())
                self.assertFalse(errors)
                self.assertEqual(AppSettings(settings.path).values["brightness"], 64)

    def test_desktop_window_can_close_without_stopping_core(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = AppSettings(Path(directory) / "settings.json")
            settings.values["tracker_idx"] = 4
            app = LightTableCV(desktop=True, settings=settings)
            try:
                self.assertTrue(app.ui.is_open())
                app.ui._bright_var.set(73)
                app._desktop_tick()
                self.assertEqual(app.settings.values["brightness"], 73)
                app._ctrl_state.queue_operator({"type": "settings", "tracker_name": app.tracker.name,
                                                "settings": {"brightness": 61}, "tracker_settings": {}})
                app._operator_tick()
                self.assertEqual(app.ui._bright_var.get(), 61)
                self.assertEqual(app.settings.read()["Brightness"], 61)
                app.ui._on_close()
                app._desktop_tick()
                self.assertFalse(app._stop_requested)
                self.assertEqual(app.settings.read()["Tracker"], 4)
            finally:
                app._ctrl_state.preview.close()
                app.bridge.close()

    def test_godot_udp_reset_does_not_stop_status_recovery(self):
        from web_remote import ControlState, WebRemote
        state = ControlState()
        remote = WebRemote(state)
        sock = Mock()
        remote._udp_socket = sock

        def receive(_size):
            if sock.recvfrom.call_count == 1:
                raise ConnectionResetError(10054, "no listener")
            remote._stop_event.set()
            return (json.dumps({"type": "godot_status", "scene": "Water"}).encode(),
                    ("127.0.0.1", 7000))

        sock.recvfrom.side_effect = receive
        remote._listen_godot_status()
        self.assertEqual(state.get_status()["scene"], "Water")
        self.assertEqual(sock.recvfrom.call_count, 2)

    def test_restart_occurs_after_resources_are_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = AppSettings(Path(directory) / "settings.json")
            settings.values["tracker_idx"] = 4
            app = LightTableCV(desktop=False, settings=settings)
            app._restart_requested = True
            with patch.object(app, "_run_loop"), patch("main.subprocess.Popen") as launch:
                app.run()
            self.assertEqual(app.bridge.sock.fileno(), -1)
            launch.assert_called_once()

    def test_lifecycle_requires_authentication_and_confirmation(self):
        from web_remote import ControlState, WebRemote
        state = ControlState()
        remote = WebRemote(state)
        remote._cfg["pin"] = "246810"
        client = remote._create_app().test_client()
        self.assertEqual(client.post("/operator/lifecycle", json={
            "action": "restart", "confirm": True}).status_code, 401)
        client.post("/login", json={"pin": "246810"})
        self.assertEqual(client.post("/operator/lifecycle", json={
            "action": "restart"}).status_code, 400)
        self.assertEqual(client.post("/operator/lifecycle", json={
            "action": "restart", "confirm": True}).status_code, 200)
        self.assertEqual(state.pop_operator_commands()[0]["action"], "restart")


if __name__ == "__main__":
    unittest.main()
