"""Shared detection identity, lifecycle, and interaction-event generation."""

import math


class TrackingManager:
    """Associate unordered detector outputs with persistent IDs by proximity."""

    def __init__(self, max_distance=120.0, stale_after=0.5):
        self.max_distance = float(max_distance)
        self.stale_after = float(stale_after)
        self._tracks = {}
        self._next_id = 1

    def reset(self):
        self._tracks.clear()

    def update(self, detections, timestamp):
        timestamp = float(timestamp)
        active = {
            track_id: track for track_id, track in self._tracks.items()
            if timestamp - track["timestamp"] <= self.stale_after
        }
        expired = sorted(set(self._tracks) - set(active))
        pairs = []
        for detection_index, detection in enumerate(detections):
            for track_id, track in active.items():
                distance = math.hypot(
                    float(detection["x"]) - track["x"],
                    float(detection["y"]) - track["y"],
                )
                if distance <= self.max_distance:
                    pairs.append((distance, detection_index, track_id))
        pairs.sort()
        assigned_detections = set()
        assigned_tracks = set()
        assignments = {}
        for _, detection_index, track_id in pairs:
            if detection_index not in assigned_detections and track_id not in assigned_tracks:
                assignments[detection_index] = track_id
                assigned_detections.add(detection_index)
                assigned_tracks.add(track_id)

        stable = []
        for index, detection in enumerate(detections):
            track_id = assignments.get(index)
            if track_id is None:
                track_id = self._next_id
                self._next_id += 1
            previous = active.get(track_id)
            dt = timestamp - previous["timestamp"] if previous else 0.0
            dx = float(detection["x"]) - previous["x"] if previous else 0.0
            dy = float(detection["y"]) - previous["y"] if previous else 0.0
            item = dict(detection)
            item.update({
                "id": track_id,
                "timestamp": timestamp,
                "velocity": (dx / dt, dy / dt) if dt > 1e-6 else (0.0, 0.0),
            })
            if dt > 1e-6 and math.hypot(dx, dy) > 1e-6:
                item["direction"] = (dx / math.hypot(dx, dy), dy / math.hypot(dx, dy))
            stable.append(item)
            self._tracks[track_id] = {
                "x": float(detection["x"]),
                "y": float(detection["y"]),
                "timestamp": timestamp,
            }
        for track_id in expired:
            self._tracks.pop(track_id, None)
        return stable, expired


class InteractionEventGenerator:
    """Derive interaction lifecycle events; does not infer physical surface contact."""

    def __init__(self, lost_after=0.5, dwell_after=0.8, swipe_distance=0.22):
        self.lost_after = float(lost_after)
        self.dwell_after = float(dwell_after)
        self.swipe_distance = float(swipe_distance)
        self._tracks = {}

    @staticmethod
    def _event(event_type, detection, timestamp, velocity=None):
        result = {
            "type": "interaction",
            "id": int(detection["id"]),
            "x": float(detection["x"]),
            "y": float(detection["y"]),
            "state": event_type,
            "event": event_type,
            "tracker": detection.get("tracker", "Unknown"),
            "timestamp": float(timestamp),
        }
        confidence = detection.get("confidence")
        if confidence is not None:
            result["confidence"] = float(confidence)
        if velocity is not None:
            result["velocity"] = {"x": float(velocity[0]), "y": float(velocity[1])}
        direction = detection.get("direction")
        if direction is not None:
            result["direction"] = {"x": float(direction[0]), "y": float(direction[1])}
        return result

    def reset(self):
        self._tracks.clear()

    def close_all(self, timestamp):
        events = []
        for track_id, previous in list(self._tracks.items()):
            detection = {
                "id": track_id,
                "x": previous["position"][0],
                "y": previous["position"][1],
                "tracker": previous.get("tracker", "Unknown"),
            }
            events.append(self._event("exit", detection, timestamp))
        self._tracks.clear()
        return events

    def update(self, detections, timestamp):
        timestamp = float(timestamp)
        events = []
        seen = set()
        for detection in detections:
            track_id = int(detection["id"])
            seen.add(track_id)
            previous = self._tracks.get(track_id)
            position = (float(detection["x"]), float(detection["y"]))
            if previous is None:
                self._tracks[track_id] = {
                    "last_seen": timestamp, "entered": timestamp, "position": position,
                    "anchor": position, "anchor_time": timestamp, "dwell_sent": False,
                }
                events.append(self._event("enter", detection, timestamp, detection.get("velocity")))
                continue

            elapsed = timestamp - previous["last_seen"]
            if elapsed > self.lost_after:
                events.append(self._event("exit", {
                    "id": track_id,
                    "x": previous["position"][0],
                    "y": previous["position"][1],
                    "tracker": previous.get("tracker", "Unknown"),
                }, previous["last_seen"] + self.lost_after))
                previous.update({
                    "last_seen": timestamp, "entered": timestamp, "position": position,
                    "anchor": position, "anchor_time": timestamp, "dwell_sent": False,
                })
                events.append(self._event("enter", detection, timestamp, detection.get("velocity")))
                continue

            previous["last_seen"] = timestamp
            dx, dy = position[0] - previous["position"][0], position[1] - previous["position"][1]
            previous["position"] = position
            velocity = (dx / elapsed, dy / elapsed) if elapsed > 1e-6 else detection.get("velocity")
            event_detection = dict(detection)
            if velocity is not None and math.hypot(*velocity) > 1e-6:
                event_detection["direction"] = (
                    velocity[0] / math.hypot(*velocity),
                    velocity[1] / math.hypot(*velocity),
                )
            events.append(self._event("move", event_detection, timestamp, velocity))
            anchor = previous["anchor"]
            anchor_dt = timestamp - previous["anchor_time"]
            anchor_dx, anchor_dy = position[0] - anchor[0], position[1] - anchor[1]
            if 0 < anchor_dt <= 0.6 and math.hypot(anchor_dx, anchor_dy) >= self.swipe_distance:
                distance = math.hypot(anchor_dx, anchor_dy)
                swipe_detection = dict(event_detection)
                swipe_detection["direction"] = (anchor_dx / distance, anchor_dy / distance)
                events.append(self._event(
                    "swipe", swipe_detection, timestamp,
                    (anchor_dx / anchor_dt, anchor_dy / anchor_dt),
                ))
                previous["anchor"] = position
                previous["anchor_time"] = timestamp
            elif anchor_dt > 0.6:
                previous["anchor"] = position
                previous["anchor_time"] = timestamp
            if not previous["dwell_sent"] and timestamp - previous["entered"] >= self.dwell_after:
                events.append(self._event("dwell", event_detection, timestamp, velocity))
                previous["dwell_sent"] = True

        for track_id, previous in list(self._tracks.items()):
            if track_id not in seen and timestamp - previous["last_seen"] > self.lost_after:
                detection = {
                    "id": track_id,
                    "x": previous["position"][0],
                    "y": previous["position"][1],
                    "tracker": previous.get("tracker", "Unknown"),
                }
                events.append(self._event("exit", detection, timestamp))
                del self._tracks[track_id]
        for detection in detections:
            track = self._tracks.get(int(detection["id"]))
            if track is not None:
                track["tracker"] = detection.get("tracker", "Unknown")
        return events
