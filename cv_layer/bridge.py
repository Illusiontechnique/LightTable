import socket
import json

class InteractionBridge:
    def __init__(self, host="127.0.0.1", port=7000, motion_port=4242):
        self.host = host
        self.port = port
        self.motion_port = motion_port
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def send(self, data):
        message = json.dumps(data).encode('utf-8')
        self.sock.sendto(message, (self.host, self.port))

    def send_motion_frame(self, data):
        if len(data) != 160 * 120:
            raise ValueError("Motion frames must contain exactly 19,200 bytes")
        self.sock.sendto(data, (self.host, self.motion_port))

    def close(self):
        self.sock.close()
