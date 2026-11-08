import socket
import json

class InteractionBridge:
    def __init__(self, host="127.0.0.1", port=7000):
        self.host = host
        self.port = port
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def send(self, data):
        message = json.dumps(data).encode('utf-8')
        self.sock.sendto(message, (self.host, self.port))

    def close(self):
        self.sock.close()
