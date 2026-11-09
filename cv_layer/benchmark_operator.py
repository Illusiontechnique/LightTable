"""Reproducible synthetic-frame operator benchmark; no camera is opened."""

import argparse
import ctypes
import json
import os
import sys
import tempfile
import time
from pathlib import Path

import cv2
import numpy as np

from app_settings import AppSettings
from main import LightTableCV


def memory_mib():
    if os.name == "nt":
        from ctypes import wintypes

        class Counters(ctypes.Structure):
            _fields_ = [("cb", wintypes.DWORD), ("faults", wintypes.DWORD),
                        ("peak_working_set", ctypes.c_size_t), ("working_set", ctypes.c_size_t),
                        ("peak_paged", ctypes.c_size_t), ("paged", ctypes.c_size_t),
                        ("peak_nonpaged", ctypes.c_size_t), ("nonpaged", ctypes.c_size_t),
                        ("pagefile", ctypes.c_size_t), ("peak_pagefile", ctypes.c_size_t)]
        counters = Counters()
        counters.cb = ctypes.sizeof(counters)
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        psapi = ctypes.WinDLL("psapi", use_last_error=True)
        kernel.GetCurrentProcess.restype = wintypes.HANDLE
        psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
        if not psapi.GetProcessMemoryInfo(kernel.GetCurrentProcess(), ctypes.byref(counters), counters.cb):
            raise ctypes.WinError(ctypes.get_last_error())
        return counters.working_set / 1048576
    import resource
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return rss / (1048576 if sys.platform == "darwin" else 1024)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--desktop", action="store_true")
    parser.add_argument("--preview", action="store_true")
    parser.add_argument("--seconds", type=float, default=8)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as directory:
        settings = AppSettings(Path(directory) / "settings.json")
        settings.values["tracker_idx"] = 4
        settings.values["resolution"] = "640 × 480"
        app = LightTableCV(desktop=args.desktop, settings=settings)
        app.bridge.send = lambda packet: None
        app.bridge.send_motion_frame = lambda data: None
        if app.ui:
            app.ui._preview_on = args.preview
        frame = np.zeros((480, 640, 3), np.uint8)
        start = time.monotonic()
        cpu_start = time.process_time()
        frames = 0
        try:
            while time.monotonic() - start < args.seconds:
                now = time.monotonic()
                frame.fill(0)
                x = 20 + (frames * 7) % 500
                cv2.rectangle(frame, (x, 150), (x + 80, 260), (220, 220, 220), -1)
                if args.preview and not args.desktop:
                    app._ctrl_state.preview.request("overlay")
                output = app.process_frame(frame, settings.read(), now)
                if args.preview and args.desktop:
                    app.ui.update_preview(output)
                if args.desktop:
                    app.ui.tick()
                if args.preview and not args.desktop:
                    app._ctrl_state.preview.submit({"overlay": app._remote_overlay} if
                                                   hasattr(app, "_remote_overlay") else {})
                frames += 1
                time.sleep(max(0, 1 / 30 - (time.monotonic() - now)))
            elapsed = time.monotonic() - start
            print(json.dumps({"mode": "desktop" if args.desktop else "headless",
                              "preview": args.preview, "elapsed_s": round(elapsed, 2),
                              "fps": round(frames / elapsed, 2),
                              "processing_fps": round(len(app._processing_times) / sum(app._processing_times), 2),
                              "cpu_percent_one_core": round(100 * (time.process_time() - cpu_start) / elapsed, 2),
                              "working_set_mib": round(memory_mib(), 2)}))
        finally:
            app._ctrl_state.preview.close()
            app.bridge.close()
            if app.ui:
                app.ui._on_close()


if __name__ == "__main__":
    main()
