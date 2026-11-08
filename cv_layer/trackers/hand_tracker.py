import cv2
import mediapipe as mp
import math
from .base_tracker import BaseTracker


# Palm-base landmarks used for palm-center calculation
_PALM_LM = [0, 5, 9, 13, 17]


class HandTracker(BaseTracker):
    """
    MediaPipe Hands — up to N hands.
    Target Mode:
      0 = palm centre
      1 = palm centre, switching to the index tip for an isolated pointing finger
      2 = always the index fingertip
    """

    name = "MediaPipe Hands"

    def __init__(self):
        self._detect_conf   = 50   # trackbar 1-100
        self._track_conf    = 50
        self._max_hands     = 4
        self._draw_skel     = 1
        self._target_mode   = 1
        self._pose_by_hand  = {}
        self._pose_candidate = {}
        self._pose_candidate_frames = {}
        self.mp_hands = mp.solutions.hands
        self.mp_draw  = mp.solutions.drawing_utils
        self._last_results = None
        self._init_hands()

    # ------------------------------------------------------------------
    def _init_hands(self):
        if hasattr(self, "hands"):
            self.hands.close()
        self.hands = self.mp_hands.Hands(
            static_image_mode=False,
            max_num_hands=self._max_hands,
            min_detection_confidence=self._detect_conf / 100.0,
            min_tracking_confidence=self._track_conf  / 100.0,
        )

    # ------------------------------------------------------------------
    @staticmethod
    def _xyz(landmark):
        return (float(landmark.x), float(landmark.y), float(getattr(landmark, "z", 0.0)))

    @classmethod
    def _finger_extended(cls, lm, mcp_index, pip_index, tip_index):
        """Check finger straightness and extension relative to the wrist, independent of image up/down."""
        wrist = cls._xyz(lm.landmark[0])
        mcp = cls._xyz(lm.landmark[mcp_index])
        pip = cls._xyz(lm.landmark[pip_index])
        tip = cls._xyz(lm.landmark[tip_index])
        toward_mcp = tuple(a - b for a, b in zip(mcp, pip))
        toward_tip = tuple(a - b for a, b in zip(tip, pip))
        dot = sum(a * b for a, b in zip(toward_mcp, toward_tip))
        lengths = math.sqrt(sum(v * v for v in toward_mcp)) * math.sqrt(
            sum(v * v for v in toward_tip)
        )
        if lengths < 1e-8:
            return False
        straightness = dot / lengths
        wrist_to_pip = math.dist(wrist, pip)
        wrist_to_tip = math.dist(wrist, tip)
        return straightness < -0.25 and wrist_to_tip > wrist_to_pip * 1.08

    @classmethod
    def classify_pose(cls, lm):
        """Return pointing only when index is extended and the other long fingers are curled."""
        extended = {
            "index": cls._finger_extended(lm, 5, 6, 8),
            "middle": cls._finger_extended(lm, 9, 10, 12),
            "ring": cls._finger_extended(lm, 13, 14, 16),
            "pinky": cls._finger_extended(lm, 17, 18, 20),
        }
        return "pointing" if (
            extended["index"] and not any(
                extended[name] for name in ("middle", "ring", "pinky")
            )
        ) else "hand"

    @staticmethod
    def _palm_center(lm, w: int, h: int):
        """Average position of wrist + 4 MCP joints in pixel coords."""
        cx = sum(lm.landmark[i].x for i in _PALM_LM) / len(_PALM_LM)
        cy = sum(lm.landmark[i].y for i in _PALM_LM) / len(_PALM_LM)
        return cx * w, cy * h

    def _stable_pose(self, hand_index, candidate):
        current = self._pose_by_hand.get(hand_index, "hand")
        if candidate == current:
            self._pose_candidate.pop(hand_index, None)
            self._pose_candidate_frames.pop(hand_index, None)
            return current
        if self._pose_candidate.get(hand_index) != candidate:
            self._pose_candidate[hand_index] = candidate
            self._pose_candidate_frames[hand_index] = 1
        else:
            self._pose_candidate_frames[hand_index] += 1
        if self._pose_candidate_frames[hand_index] >= 3:
            self._pose_by_hand[hand_index] = candidate
            self._pose_candidate.pop(hand_index, None)
            self._pose_candidate_frames.pop(hand_index, None)
            return candidate
        return current

    def _target_for_hand(self, hand_index, lm, width, height):
        candidate = self.classify_pose(lm)
        pose = self._stable_pose(hand_index, candidate)
        use_index = self._target_mode == 2 or (
            self._target_mode == 1 and pose == "pointing"
        )
        if use_index:
            tip = lm.landmark[8]
            x, y = tip.x * width, tip.y * height
            target = "index"
        else:
            x, y = self._palm_center(lm, width, height)
            target = "palm"
        return {
            "id": hand_index, "x": x, "y": y,
            "target": target, "gesture": pose,
        }

    # ------------------------------------------------------------------
    def process(self, frame) -> list:
        h, w = frame.shape[:2]
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        self._last_results = self.hands.process(rgb)
        detections = []
        if self._last_results.multi_hand_landmarks:
            for i, lm in enumerate(self._last_results.multi_hand_landmarks):
                detections.append(self._target_for_hand(i, lm, w, h))
        else:
            self._pose_by_hand.clear()
            self._pose_candidate.clear()
            self._pose_candidate_frames.clear()
        return detections

    def draw_debug(self, frame, detections):
        if self._draw_skel and self._last_results and self._last_results.multi_hand_landmarks:
            h, w = frame.shape[:2]
            for hand_index, lm in enumerate(self._last_results.multi_hand_landmarks):
                self.mp_draw.draw_landmarks(frame, lm, self.mp_hands.HAND_CONNECTIONS)
                stable_pose = self._pose_by_hand.get(hand_index, "hand")
                index = lm.landmark[8]
                index_pos = (int(index.x * w), int(index.y * h))
                palm_pos = self._palm_center(lm, w, h)
                use_index = self._target_mode == 2 or (
                    self._target_mode == 1 and stable_pose == "pointing"
                )
                cv2.circle(frame, (int(palm_pos[0]), int(palm_pos[1])), 7, (255, 180, 0), -1)
                cv2.circle(frame, index_pos, 8, (0, 220, 255), -1)
                cv2.circle(frame, index_pos, 11, (255, 255, 255), 1)
                target = index_pos if use_index else palm_pos
                cv2.drawMarker(
                    frame, (int(target[0]), int(target[1])), (0, 255, 0),
                    cv2.MARKER_CROSS, 18, 2,
                )
                cv2.putText(
                    frame,
                    f"{stable_pose.upper()} -> {'INDEX' if use_index else 'PALM'}",
                    (int(palm_pos[0]) + 8, int(palm_pos[1]) - 8),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 0), 1,
                )
        return frame

    # ------------------------------------------------------------------
    def get_trackbar_settings(self):
        return [
            {"name": "Detect Conf",  "max": 100, "default": 50},
            {"name": "Track Conf",   "max": 100, "default": 50},
            {"name": "Max Hands",    "max": 6,   "default": 4},
            {"name": "Draw Skel",    "max": 1,   "default": 1},
            {"name": "Target Mode",  "max": 2,   "default": 1},
        ]

    def on_trackbar(self, name, value):
        if   name == "Detect Conf":  self._detect_conf  = max(1, value); self._init_hands()
        elif name == "Track Conf":   self._track_conf   = max(1, value); self._init_hands()
        elif name == "Max Hands":    self._max_hands    = max(1, value); self._init_hands()
        elif name == "Draw Skel":    self._draw_skel    = value
        elif name == "Target Mode":  self._target_mode = max(0, min(2, value))

    def reset(self):
        self._last_results = None
        self._pose_by_hand.clear()
        self._pose_candidate.clear()
        self._pose_candidate_frames.clear()
        self._init_hands()

    def close(self):
        if hasattr(self, "hands"):
            self.hands.close()
            del self.hands
