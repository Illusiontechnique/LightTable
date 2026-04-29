import cv2
import mediapipe as mp
import numpy as np
from bridge import InteractionBridge
from calibration import Calibration
import time

class LightTableCV:
    def __init__(self, osc_ip="127.0.0.1", osc_port=7000):
        self.mp_hands = mp.solutions.hands
        self.hands = self.mp_hands.Hands(
            static_image_mode=False,
            max_num_hands=4,
            min_detection_confidence=0.5,
            min_tracking_confidence=0.5
        )
        self.mp_draw = mp.solutions.drawing_utils
        self.bridge = InteractionBridge(osc_ip, osc_port)
        self.calibration = Calibration()
        self.debug_mode = True

    def send_interaction(self, id, x, y, state="move"):
        # Map raw camera coordinates to calibrated surface coordinates
        cal_x, cal_y = self.calibration.apply(x, y)
        
        # Normalize to 0.0 - 1.0 based on target resolution (1920x1080)
        norm_x = cal_x / 1920.0
        norm_y = cal_y / 1080.0

        self.bridge.send({
            "type": "interaction",
            "id": id,
            "x": float(norm_x),
            "y": float(norm_y),
            "state": state
        })

    def on_mouse(self, event, x, y, flags, param):
        if event == cv2.EVENT_LBUTTONDOWN:
            if len(self.calibration.points) < 4:
                self.calibration.points.append([x, y])
                print(f"Added calibration point: {x}, {y}")
                if len(self.calibration.points) == 4:
                    self.calibration.get_warp_matrix((1,1))
                    print("Calibration complete.")

    def process_frame(self, frame):
        # Show calibration points
        for p in self.calibration.points:
            cv2.circle(frame, tuple(p), 5, (0, 255, 0), -1)

        rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        results = self.hands.process(rgb_frame)

        if results.multi_hand_landmarks:
            for hand_id, hand_landmarks in enumerate(results.multi_hand_landmarks):
                # Landmarks are normalized 0-1 of the CAMERA frame
                h, w, _ = frame.shape
                index_tip = hand_landmarks.landmark[8]
                raw_x, raw_y = index_tip.x * w, index_tip.y * h
                
                self.send_interaction(hand_id, raw_x, raw_y)

                if self.debug_mode:
                    self.mp_draw.draw_landmarks(frame, hand_landmarks, self.mp_hands.HAND_CONNECTIONS)

        return frame

    def run(self):
        cap = cv2.VideoCapture(0)
        cv2.namedWindow('LightTable CV Debug')
        cv2.setMouseCallback('LightTable CV Debug', self.on_mouse)
        
        print("CV Layer Started. Click 4 corners of projection surface to calibrate.")
        
        while cap.is_opened():
            success, frame = cap.read()
            if not success: break

            debug_frame = self.process_frame(frame)
            cv2.imshow('LightTable CV Debug', debug_frame)
            
            key = cv2.waitKey(5) & 0xFF
            if key == 27: break
            if key == ord('c'): self.calibration.points = []

        cap.release()
        cv2.destroyAllWindows()

if __name__ == "__main__":
    lt_cv = LightTableCV()
    lt_cv.run()
