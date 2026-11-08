"""Validated, camera-configuration-aware four-corner perspective calibration."""

import hashlib
import json
import os
from pathlib import Path
import tempfile

import cv2
import numpy as np


class Calibration:
    UNCALIBRATED = "uncalibrated"
    SELECTING = "selecting"
    VALIDATING = "validating"
    CALIBRATED = "calibrated"
    ERROR = "error"

    CORNER_NAMES = ("Top-Left", "Top-Right", "Bottom-Right", "Bottom-Left")

    def __init__(self, config_path=None, target_size=(1920, 1080)):
        self.config_path = Path(config_path) if config_path else Path(__file__).with_name("calibration.json")
        self.target_size = tuple(map(int, target_size))
        self.points = []
        self.matrix = None
        self.state = self.UNCALIBRATED
        self.message = "No compatible calibration loaded"
        self.signature = None
        self.active_profile = None
        self._previous = None
        self._profiles = {}
        self._legacy_matrix_found = False
        self._load_error = None
        self._read_profiles()

    @staticmethod
    def make_signature(camera_idx, source_size, processing_size, flip_h):
        return {
            "camera_idx": int(camera_idx),
            "source_size": [int(source_size[0]), int(source_size[1])],
            "processing_size": [int(processing_size[0]), int(processing_size[1])],
            "flip_h": bool(flip_h),
        }

    @staticmethod
    def _profile_key(signature):
        encoded = json.dumps(signature, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()[:20]

    def _read_profiles(self):
        if not self.config_path.exists():
            return
        try:
            data = json.loads(self.config_path.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                raise ValueError("calibration root must be a JSON object")
            profiles = data.get("profiles", [])
            if not isinstance(profiles, list):
                raise ValueError("calibration profiles must be a JSON array")
            for profile in profiles:
                if isinstance(profile, dict) and isinstance(profile.get("signature"), dict):
                    key = self._profile_key(profile["signature"])
                    self._profiles[key] = profile
                else:
                    print("[Calibration] Ignoring malformed saved profile")
                    self._load_error = "Saved calibration contains a malformed profile"
            if "matrix" in data and not profiles:
                # Legacy matrix files have no camera/resolution/flip identity and
                # therefore cannot be safely activated automatically.
                self._legacy_matrix_found = True
                self.state = self.ERROR
                self.message = "Saved calibration has no camera metadata; recalibrate"
        except (OSError, ValueError, TypeError) as exc:
            self.state = self.ERROR
            self.message = f"Calibration file could not be read: {exc}"
            self._load_error = self.message

    def set_context(self, signature):
        """Select only a profile whose complete camera configuration matches."""
        signature = dict(signature)
        if signature == self.signature:
            return self.state == self.CALIBRATED
        self.signature = signature
        self.points = []
        self.matrix = None
        self.active_profile = None
        self._previous = None
        profile = self._profiles.get(self._profile_key(signature))
        if profile and self._validate_saved_profile(profile, signature):
            self.matrix = np.asarray(profile["matrix"], dtype=np.float64)
            self.points = [list(point) for point in profile["points"]]
            self.active_profile = self._profile_key(signature)
            self.state = self.CALIBRATED
            self.message = "Calibration loaded for active camera configuration"
            return True
        self.state = (
            self.ERROR
            if self._profiles or self._legacy_matrix_found or self._load_error
            else self.UNCALIBRATED
        )
        self.message = (
            self._load_error
            if self._load_error
            else "Saved calibration is incompatible with active camera settings"
            if self._profiles
            else "Saved calibration has no camera metadata; recalibrate"
            if self._legacy_matrix_found
            else "No calibration saved for active camera settings"
        )
        return False

    @staticmethod
    def validate_points(points, frame_size):
        if len(points) != 4:
            return False, "Select exactly four corners"
        width, height = frame_size
        pts = np.asarray(points, dtype=np.float64)
        if pts.shape != (4, 2) or not np.isfinite(pts).all():
            return False, "Calibration points must be finite image coordinates"
        if width <= 0 or height <= 0 or np.any(pts[:, 0] < 0) or np.any(pts[:, 0] >= width) or np.any(pts[:, 1] < 0) or np.any(pts[:, 1] >= height):
            return False, "A selected corner is outside the camera image"
        if pts[0].sum() > np.min(pts[1:].sum(axis=1)):
            return False, "Select corners in Top-Left, Top-Right, Bottom-Right, Bottom-Left order"
        edges = np.roll(pts, -1, axis=0) - pts
        following = np.roll(edges, -1, axis=0)
        crosses = edges[:, 0] * following[:, 1] - edges[:, 1] * following[:, 0]
        if np.any(crosses <= 1e-6):
            return False, "Corners must form a non-degenerate convex region in the indicated order"
        area = abs(float(np.dot(pts[:, 0], np.roll(pts[:, 1], -1)) -
                         np.dot(pts[:, 1], np.roll(pts[:, 0], -1)))) * 0.5
        if area < max(100.0, width * height * 0.005):
            return False, "Selected region is too small to calibrate reliably"
        return True, ""

    def start(self):
        if self._previous is None:
            self._previous = (
                None if self.matrix is None else self.matrix.copy(),
                self.state,
                self.active_profile,
                self.message,
                [list(point) for point in self.points],
            )
        self.matrix = None
        self.points = []
        self.state = self.SELECTING
        self.message = f"Select {self.CORNER_NAMES[0]}"

    def add_point(self, x, y, frame_size):
        if self.state != self.SELECTING:
            return False
        width, height = frame_size
        if not (0 <= x < width and 0 <= y < height):
            self.state = self.ERROR
            self.message = "Selected corner is outside the camera image"
            return False
        self.points.append([int(x), int(y)])
        if len(self.points) < 4:
            self.message = f"Select {self.CORNER_NAMES[len(self.points)]}"
            return True
        return self.validate(frame_size)

    def undo(self):
        if self.points and self.state in (self.SELECTING, self.ERROR, self.VALIDATING):
            self.points.pop()
            self.state = self.SELECTING
            self.matrix = None
            self.message = f"Select {self.CORNER_NAMES[len(self.points)]}"
            return True
        return False

    def reset(self):
        self.points = []
        self.matrix = None
        self._previous = None
        self.active_profile = None
        self.state = self.UNCALIBRATED
        self.message = "Calibration reset; select four corners"

    def cancel(self):
        if self._previous is None or self.state not in (self.SELECTING, self.VALIDATING, self.ERROR):
            return
        self.points = []
        if self._previous is None:
            self.matrix = None
            self.state = self.UNCALIBRATED
            self.message = "Calibration cancelled; no previous calibration"
        else:
            self.matrix, self.state, self.active_profile, self.message, self.points = self._previous
        self._previous = None

    def validate(self, frame_size):
        self.state = self.VALIDATING
        valid, reason = self.validate_points(self.points, frame_size)
        if not valid:
            self.state = self.ERROR
            self.message = reason
            return False
        dst = np.float32([
            [0, 0],
            [self.target_size[0] - 1, 0],
            [self.target_size[0] - 1, self.target_size[1] - 1],
            [0, self.target_size[1] - 1],
        ])
        matrix = cv2.getPerspectiveTransform(np.float32(self.points), dst).astype(np.float64)
        if not np.isfinite(matrix).all() or abs(float(np.linalg.det(matrix))) < 1e-12:
            self.state = self.ERROR
            self.message = "Calculated perspective transform is degenerate"
            return False
        mapped = cv2.perspectiveTransform(np.float32(self.points).reshape(1, 4, 2), matrix)[0]
        if not np.isfinite(mapped).all() or np.max(np.abs(mapped - dst)) > max(self.target_size) * 1e-3:
            self.state = self.ERROR
            self.message = "Perspective transform failed corner validation"
            return False
        self.matrix = matrix
        self.active_profile = None
        self.state = self.CALIBRATED
        self.message = "Calibration valid; save profile to keep it"
        self._previous = None
        return True

    def get_warp_matrix(self, frame_size, target_size=None):
        """Compatibility wrapper for the former four-point API."""
        if target_size is not None and tuple(target_size) != self.target_size:
            self.target_size = tuple(map(int, target_size))
        if len(self.points) != 4:
            return None
        return self.matrix if self.validate(frame_size) else None

    def _validate_saved_profile(self, profile, signature):
        try:
            matrix = np.asarray(profile["matrix"], dtype=np.float64)
            source_size = signature["processing_size"]
            points = profile["points"]
            if tuple(profile.get("target_size", ())) != self.target_size:
                return False
            if matrix.shape != (3, 3) or not np.isfinite(matrix).all():
                return False
            if abs(float(np.linalg.det(matrix))) < 1e-12:
                return False
            valid, _ = self.validate_points(points, source_size)
            if not valid:
                return False
            expected = cv2.getPerspectiveTransform(
                np.float32(points),
                np.float32([[0, 0], [self.target_size[0] - 1, 0],
                            [self.target_size[0] - 1, self.target_size[1] - 1],
                            [0, self.target_size[1] - 1]])
            )
            # Saved matrix must still map its stored corners to the configured target.
            mapped = cv2.perspectiveTransform(np.float32(points).reshape(1, 4, 2), matrix)[0]
            target = cv2.perspectiveTransform(np.float32(points).reshape(1, 4, 2), expected)[0]
            return np.isfinite(mapped).all() and np.max(np.abs(mapped - target)) <= max(self.target_size) * 1e-3
        except (KeyError, TypeError, ValueError, cv2.error):
            return False

    def save(self, name=None):
        if self.state != self.CALIBRATED or self.matrix is None or self.signature is None:
            raise ValueError("Cannot save an unvalidated or configuration-free calibration")
        valid, reason = self.validate_points(self.points, self.signature["processing_size"])
        if not valid:
            self.state = self.ERROR
            self.message = reason
            raise ValueError(reason)
        key = self._profile_key(self.signature)
        self._profiles[key] = {
            "name": name or f"Camera {self.signature['camera_idx']} "
                    f"{self.signature['processing_size'][0]}x{self.signature['processing_size'][1]}",
            "signature": self.signature,
            "target_size": list(self.target_size),
            "points": self.points,
            "matrix": self.matrix.tolist(),
        }
        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"version": 2, "profiles": list(self._profiles.values())}
        fd, temp_path = tempfile.mkstemp(prefix=self.config_path.name, dir=str(self.config_path.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(payload, f, indent=2)
            os.replace(temp_path, self.config_path)
        except OSError:
            try:
                os.unlink(temp_path)
            except OSError:
                pass
            raise
        self.active_profile = key
        self._load_error = None
        self._legacy_matrix_found = False
        self.message = "Calibration profile saved"
        return key

    def load_profile(self):
        if self.signature is None:
            return False
        self._previous = None
        profile = self._profiles.get(self._profile_key(self.signature))
        if not profile or not self._validate_saved_profile(profile, self.signature):
            self.matrix = None
            self.points = []
            self.active_profile = None
            self.state = self.ERROR if self._profiles or self._load_error else self.UNCALIBRATED
            self.message = self._load_error or "No valid saved calibration for active camera settings"
            return False
        self.matrix = np.asarray(profile["matrix"], dtype=np.float64)
        self.points = [list(point) for point in profile["points"]]
        self.active_profile = self._profile_key(self.signature)
        self.state = self.CALIBRATED
        self.message = "Calibration profile loaded"
        return True

    def load(self):
        """Compatibility entry point; never loads an unverified legacy matrix."""
        return self.load_profile()

    def apply(self, x, y):
        if self.state != self.CALIBRATED or self.matrix is None:
            return x, y
        point = np.array([[[x, y]]], dtype=np.float32)
        warped = cv2.perspectiveTransform(point, self.matrix)[0][0]
        return float(warped[0]), float(warped[1])
