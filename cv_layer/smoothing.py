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
        self._timestamps: dict = {}

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
        kf.processNoiseCov      = np.eye(4, dtype=np.float32)
        kf.measurementNoiseCov  = np.eye(2, dtype=np.float32) * 4.0
        kf.errorCovPost         = np.diag([4.0, 4.0, 100.0, 100.0]).astype(np.float32)
        return kf

    def smooth(self, track_id: int, x: float, y: float, timestamp=None):
        """Returns (smoothed_x, smoothed_y) using the per-ID Kalman filter."""
        if track_id not in self._filters:
            kf = self._make_kf()
            initial = np.array([[x], [y], [0.0], [0.0]], dtype=np.float32)
            kf.statePre = initial.copy()
            kf.statePost = initial.copy()
            self._filters[track_id] = kf
            self._timestamps[track_id] = timestamp
            return float(x), float(y)

        kf = self._filters[track_id]
        previous_time = self._timestamps.get(track_id)
        dt = 1.0 / 30.0 if timestamp is None or previous_time is None else float(timestamp) - previous_time
        dt = max(1e-3, min(0.25, dt))
        kf.transitionMatrix = np.array(
            [[1, 0, dt, 0],
             [0, 1, 0, dt],
             [0, 0, 1, 0],
             [0, 0, 0, 1]], dtype=np.float32
        )
        dt2, dt3, dt4 = dt * dt, dt * dt * dt, dt * dt * dt * dt
        acceleration_variance = 25.0
        kf.processNoiseCov = acceleration_variance * np.array(
            [[dt4 / 4, 0, dt3 / 2, 0],
             [0, dt4 / 4, 0, dt3 / 2],
             [dt3 / 2, 0, dt2, 0],
             [0, dt3 / 2, 0, dt2]], dtype=np.float32
        )
        self._timestamps[track_id] = timestamp
        kf.predict()
        corrected = kf.correct(np.array([[x], [y]], dtype=np.float32))
        return float(corrected[0, 0]), float(corrected[1, 0])

    def clear(self, track_id=None):
        if track_id is None:
            self._filters.clear()
            self._timestamps.clear()
        else:
            self._filters.pop(track_id, None)
            self._timestamps.pop(track_id, None)


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
