# LightTable

An affordable, portable interactive projection system that transforms ordinary surfaces into engaging sensory environments.

## Project Structure

- `cv_layer/`: Python + OpenCV for hand detection (Mediapipe), gesture zones, and motion detection.
- `visual_layer/`: Godot Engine 4.x project for water ripples, fish follow, and particle systems.
- `shared/`: Shared assets and communication protocols (OSC).

## Features

- **Interaction Detection**: Real-time hand and blob tracking.
- **Dynamic Visuals**: Responsive water ripples, fish swarms, and sensory particles.
- **Calibration Tools**: Easy camera alignment for different surfaces.
- **Lightweight**: Optimized for mini-PC hardware.

## Getting Started

### Prerequisites

- Python 3.9+
- Godot Engine 4.x
- Webcam or IR Camera
- Projector

### CV Layer Setup

1. Navigate to `cv_layer/`
2. Install dependencies: `pip install -r requirements.txt`
3. Run: `python main.py`

