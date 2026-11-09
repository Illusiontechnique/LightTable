import socket
import unittest
from unittest.mock import patch

from bridge import InteractionBridge


class MotionBridgeTests(unittest.TestCase):
    def test_motion_frame_uses_binary_port_and_exact_size(self):
        bridge = InteractionBridge()
        try:
            with patch.object(bridge, "sock", wraps=bridge.sock) as sock:
                frame = bytes(19200)
                bridge.send_motion_frame(frame)
                sock.sendto.assert_called_once_with(frame, ("127.0.0.1", 4242))
                with self.assertRaises(ValueError):
                    bridge.send_motion_frame(b"short")
        finally:
            bridge.close()

    def test_motion_frame_reaches_udp_listener(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        listener.settimeout(1)
        listener.bind(("127.0.0.1", 0))
        bridge = InteractionBridge(motion_port=listener.getsockname()[1])
        try:
            frame = bytes(range(256)) * 75
            bridge.send_motion_frame(frame)
            received, _ = listener.recvfrom(65535)
            self.assertEqual(received, frame)
        finally:
            bridge.close()
            listener.close()


if __name__ == "__main__":
    unittest.main()
