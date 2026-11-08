from abc import ABC, abstractmethod


class BaseTracker(ABC):
    """Common interface for all LightTable CV trackers."""

    name = "Base"

    @abstractmethod
    def process(self, frame) -> list:
        """
        Process a BGR camera frame.
        Returns a list of detection dicts, each containing at least:
            id (int), x (float), y (float)
        """

    def draw_debug(self, frame, detections: list):
        """Draw debug visuals onto frame in-place and return it."""
        return frame

    def get_trackbar_settings(self) -> list:
        """
        Return tracker-specific trackbar descriptors.
        Each dict: {name: str, max: int, default: int}
        """
        return []

    def on_trackbar(self, name: str, value: int):
        """Called whenever one of this tracker's trackbars changes."""

    def reset(self):
        """Reset internal state (call on camera switch or re-init)."""

    def close(self):
        """Release optional tracker resources when the application exits."""
