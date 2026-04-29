import cv2
import numpy as np
import json
import os

class Calibration:
    def __init__(self, config_path="calibration.json"):
        self.config_path = config_path
        self.points = []
        self.matrix = None
        self.load()

    def load(self):
        if os.path.exists(self.config_path):
            with open(self.config_path, 'r') as f:
                data = json.load(f)
                self.matrix = np.array(data['matrix'])
                return True
        return False

    def save(self):
        if self.matrix is not None:
            with open(self.config_path, 'w') as f:
                json.dump({'matrix': self.matrix.tolist()}, f)

    def get_warp_matrix(self, frame_size, target_size=(1920, 1080)):
        if len(self.points) == 4:
            src_pts = np.float32(self.points)
            dst_pts = np.float32([[0, 0], [target_size[0], 0], [target_size[0], target_size[1]], [0, target_size[1]]])
            self.matrix = cv2.getPerspectiveTransform(src_pts, dst_pts)
            self.save()
            return self.matrix
        return None

    def apply(self, x, y):
        if self.matrix is None:
            return x, y
        # Apply perspective transform to a single point
        point = np.array([[[x, y]]], dtype=np.float32)
        warped_point = cv2.perspectiveTransform(point, self.matrix)
        return warped_point[0][0][0], warped_point[0][0][1]
