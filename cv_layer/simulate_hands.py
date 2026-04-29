import socket
import json
import time
import random

def simulate_interaction(port=7000):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    print(f"Simulating dual-hand interaction on port {port}...")
    print("Press Ctrl+C to stop.")
    
    t = 0
    try:
        while True:
            # Create two circular movement patterns
            t += 0.05
            
            # Hand 1
            h1_x = 0.5 + 0.2 * np.cos(t)
            h1_y = 0.5 + 0.2 * np.sin(t)
            
            # Hand 2 
            h2_x = 0.5 + 0.2 * np.cos(t + np.pi)
            h2_y = 0.5 + 0.2 * np.sin(t + np.pi)
            
            for i, (x, y) in enumerate([(h1_x, h1_y), (h2_x, h2_y)]):
                data = {
                    "type": "interaction",
                    "id": i,
                    "x": float(x),
                    "y": float(y),
                    "state": "move"
                }
                sock.sendto(json.dumps(data).encode('utf-8'), ("127.0.0.1", port))
            
            time.sleep(0.016) # ~60fps
    except KeyboardInterrupt:
        print("\nSimulation stopped.")

if __name__ == "__main__":
    import numpy as np # Adding here for the math
    simulate_interaction()
