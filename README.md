# LightTable

LightTable is a portable interactive projection system. The Python/OpenCV layer captures and tracks camera input, maps it through a validated surface calibration, then sends normalized JSON interaction events over UDP to the Godot 4 visual layer.

## Project layout

- `cv_layer/` — Python capture loop, six trackers, calibration, tracking lifecycle, Tkinter controls, and LAN remote.
- `visual_layer/` — Godot project, UDP receiver, cursor layer, and interactive scenes.
- `profiles.json` — player profiles managed by the web remote.
- `last_settings.json` — last-used camera, tracker, image, and smoothing controls.
- `remote_config.json` — web remote PIN and port. See [CONFIGURATION.md](./CONFIGURATION.md).
- `cv_layer/calibration.json` — camera-specific calibration profiles, created when a profile is saved.

## Start

1. Install Python 3.9+ and Godot 4.x.
2. Install the CV dependencies: `python -m pip install -r cv_layer/requirements.txt`.
3. Launch `visual_layer/project.godot` in Godot.
4. Run `python cv_layer/main.py` from the repository root, or use `start.bat`.
5. Connect a phone to the same LAN and open the URL printed by the Python process. The generated one-run PIN is printed on startup when the configured PIN is missing or still the insecure default.

OpenCV camera capture can fail temporarily without terminating the control panel; it retries the selected camera. The virtual interaction simulator can be run separately with `python cv_layer/simulate_hands.py`; it does not require a physical camera.

## Calibration

Use the **Calibration** section in the desktop panel:

1. Select the camera, processing resolution, and horizontal-flip setting you will use.
2. Choose **Start**, then click the projected region in the live preview in order: top-left, top-right, bottom-right, bottom-left.
3. Correct a selection with **Undo**. **Cancel** restores the previous valid transform; **Reset** clears the active transform.
4. Choose **Save** to persist the validated profile. Profiles are keyed by camera index, source and processing resolutions, and horizontal flip.

Only a profile matching the current camera configuration is applied. Existing matrix-only calibration files do not contain enough information to verify compatibility and are deliberately not auto-applied; recalibrate and save a profile instead. Resolution, camera, or flip changes clear the active transform unless a matching saved profile is available.

## Tracking and interaction contract

All six existing modes remain selectable: MediaPipe Hands, Blob, Motion, Color, Edge, and Object. Tracker outputs are associated by proximity into stable runtime IDs; timestamped histories expire after temporary loss, and smoothing is applied after identity association. EMA is initialized at the first measurement; Kalman transition timing uses elapsed time.

Each interaction datagram retains the existing envelope and `state` field and adds an `event` alias. Velocity and direction are optional:

```json
{
  "type": "interaction",
  "id": 12,
  "x": 0.42,
  "y": 0.68,
  "state": "move",
  "event": "move",
  "tracker": "MediaPipe Hands",
  "timestamp": 123.456,
  "velocity": {"x": 0.1, "y": -0.02},
  "direction": {"x": 0.98, "y": -0.2}
}
```

Coordinates are normalized to `[0, 1]`; `timestamp` is monotonic process time. Lifecycle events are `enter`, `move`, `exit`, and `dwell`; `swipe` is inferred from sufficiently large, fast motion. Optional confidence is included only when a tracker provides it. `tap` is not inferred: an overhead RGB camera cannot establish physical surface contact without additional sensing. Godot scenes continue receiving the existing ID, position, state, and metadata signal; exit removes the corresponding cursor.

The web remote scene display uses Godot acknowledgements/status packets rather than treating a sent UDP request as proof that a scene loaded. Godot status returns over UDP port 7001; the receiver continues to accept interaction/control packets on port 7000.

## Tests

Run the camera-independent Python suite from the `cv_layer` directory:

```powershell
python -m unittest discover -s tests -v
```

Tests cover calibration geometry/transforms/profile compatibility/recovery, tracking identity and expiration, interaction lifecycle, remote config and control validation, player selection, scene confirmation, and mockable camera switching. Camera/projector alignment, real camera disconnect/reconnect, MediaPipe performance, and Godot rendering still require hardware or a running Godot instance for end-to-end validation.

For Python dependency and remote settings details, see [CONFIGURATION.md](./CONFIGURATION.md).
