"""Local, atomic storage for operator environment presets."""

import json
import os
import tempfile
import threading
from pathlib import Path


class EnvironmentPresets:
    def __init__(self, path=None):
        self.path = Path(path) if path else Path(__file__).parent.parent / "environment_presets.json"
        self._lock = threading.Lock()

    def _read(self):
        if not self.path.exists():
            return {}
        data = json.loads(self.path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("presets"), dict):
            raise ValueError("Invalid environment presets file")
        return data["presets"]

    def _write(self, presets):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix=".environment-presets-", dir=str(self.path.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as file:
                json.dump({"version": 1, "presets": presets}, file, indent=2)
            os.replace(name, self.path)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    @staticmethod
    def validate_name(name):
        return isinstance(name, str) and 1 <= len(name.strip()) <= 60 and name == name.strip()

    def list(self):
        with self._lock:
            return sorted(self._read())

    def get(self, name):
        with self._lock:
            return self._read().get(name)

    def save(self, name, preset):
        with self._lock:
            presets = self._read()
            if name in presets:
                raise ValueError("Preset already exists")
            if len(presets) >= 50:
                raise ValueError("Preset limit reached")
            presets[name] = preset
            self._write(presets)

    def rename(self, old, new):
        with self._lock:
            presets = self._read()
            if old not in presets:
                raise ValueError("Preset not found")
            if new in presets:
                raise ValueError("Preset already exists")
            presets[new] = presets.pop(old)
            self._write(presets)

    def delete(self, name):
        with self._lock:
            presets = self._read()
            if name not in presets:
                raise ValueError("Preset not found")
            del presets[name]
            self._write(presets)
