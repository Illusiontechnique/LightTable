import cv2
import numpy as np


class KalmanSmoother:
    """
    Per-ID constant-velocity Kalman filter.
    State vector: [x, y, vx, vy]   Measurement: [x, y]

    Very effective for smoothing noisy position data while predicting ahead to
    compensate for detection latency.  measurementNoiseCov controls how much
    the filter trusts the raw measurement vs. its own prediction.
    """

    def __init__(self):
        self._filters: dict = {}

    @staticmethod
    def _make_kf() -> cv2.KalmanFilter:
        kf = cv2.KalmanFilter(4, 2)
        # x, y observed; vx, vy inferred
        kf.measurementMatrix = np.array(
            [[1, 0, 0, 0],
             [0, 1, 0, 0]], dtype=np.float32
        )
        # Constant-velocity transition
        kf.transitionMatrix = np.array(
            [[1, 0, 1, 0],
             [0, 1, 0, 1],
             [0, 0, 1, 0],
             [0, 0, 0, 1]], dtype=np.float32
        )
        kf.processNoiseCov      = np.eye(4, dtype=np.float32) * 1e-3
        kf.measurementNoiseCov  = np.eye(2, dtype=np.float32) * 5e-2
        return kf

    def smooth(self, track_id: int, x: float, y: float):
        """Returns (smoothed_x, smoothed_y) using the per-ID Kalman filter."""
        if track_id not in self._filters:
            kf = self._make_kf()
            kf.statePre = np.array([[x], [y], [0.0], [0.0]], dtype=np.float32)
            self._filters[track_id] = kf

        kf = self._filters[track_id]
        kf.predict()
        corrected = kf.correct(np.array([[x], [y]], dtype=np.float32))
        return float(corrected[0]), float(corrected[1])

    def clear(self, track_id=None):
        if track_id is None:
            self._filters.clear()
        else:
            self._filters.pop(track_id, None)


class ExponentialSmoother:
    """
    Exponential Moving Average (EMA) per tracked ID.
    smoothed = alpha * raw + (1 - alpha) * prev_smoothed

    alpha close to 1 → very responsive but noisy.
    alpha close to 0 → very smooth but laggy.
    Default alpha=0.35 gives a good balance for hand/object tracking at ~30 fps.
    """

    def __init__(self, alpha: float = 0.35):
        self.alpha  = alpha
        self._state: dict = {}

    def set_alpha(self, alpha: float):
        self.alpha = max(0.05, min(1.0, alpha))

    def smooth(self, track_id: int, x: float, y: float):
        """Returns (smoothed_x, smoothed_y)."""
        if track_id not in self._state:
            self._state[track_id] = (x, y)
            return x, y
        px, py = self._state[track_id]
        a  = self.alpha
        sx = a * x + (1 - a) * px
        sy = a * y + (1 - a) * py
        self._state[track_id] = (sx, sy)
        return sx, sy

    def clear(self, track_id=None):
        if track_id is None:
            self._state.clear()
        else:
            self._state.pop(track_id, None)
