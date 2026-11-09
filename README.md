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

## Godot keyboard shortcuts

With the Godot window focused, press **Space** to show or hide the shortcut list.

| Key | Action |
| --- | --- |
| T | Toggle pointers |
| Y | Toggle hand skeleton |
| Left / Right | Previous / next scene |
| Up / Down | Increase / decrease quality |
| Tab | Toggle dashboard |
| C | Toggle console |
| F3 | Toggle water debug controls (in the Water scene) |
| Esc | Quit Godot |

In the interactive menu, hold a pointer over a card for 2.2 seconds to select it.

## Calibration

Use the **Calibration** section in the desktop panel:

1. Select the camera, processing resolution, and horizontal-flip setting you will use.
2. Choose **Start**, then click the projected region in the live preview in order: top-left, top-right, bottom-right, bottom-left.
3. Correct a selection with **Undo**. **Cancel** restores the previous valid transform; **Reset** clears the active transform.
4. Choose **Save** to persist the validated profile. Profiles are keyed by camera index, source and processing resolutions, and horizontal flip.

Only a profile matching the current camera configuration is applied. Existing matrix-only calibration files do not contain enough information to verify compatibility and are deliberately not auto-applied; recalibrate and save a profile instead. Resolution, camera, or flip changes clear the active transform unless a matching saved profile is available.

## Tracking and interaction contract

All six existing modes remain selectable: MediaPipe Hands, Blob, Motion, Color, Edge, and Object. Tracker outputs are associated by proximity into stable runtime IDs; timestamped histories expire after temporary loss, and smoothing is applied after identity association. EMA is initialized at the first measurement; Kalman transition timing uses elapsed time.

For MediaPipe Hands, use **Target Mode** in the CV panel: `0` follows the palm, `1` follows the palm and switches to the index fingertip after a pointing pose is stable for three frames, `2` always follows the index fingertip, and `3` uses all five fingertips as separate scene pointers. Start with `2` to compare with mouse simulation; use `3` for multi-finger scenes. Five pointers per hand can activate multiple things at once and may be less stable when hands overlap. The preview marks selected targets with green crosses. The Godot hand skeleton and landmark dots are shown by default; press `Y` to toggle them. These landmarks do not establish physical surface contact.

Mouse simulation and camera points use the same scene interaction path. Turn off **Mouse Simulation** in Godot when testing the camera so the mouse does not leave an extra pointer. Calibrate for accurate positioning. The water scene is deliberately different: it responds only to frame-difference motion, not hand points or the simulated mouse.

**Frame Motion** runs independently of the selected tracker. It compares successive downscaled camera frames, measures changed pixels, and sends motion-boundary points for other scenes and a separate intensity image for water. The spinner can use overall motion energy even without a hand pointer. In the CV panel, enable/disable frame differencing, raise **Threshold** to reject small brightness changes, and raise **Min area %** to reject small moving regions. When calibrated, analysis is restricted to the calibrated surface. Changing projector imagery, lighting, or camera movement can still produce false motion; tune the controls for the installation.

## Interactive water

The Water scene uses a GPU heightfield with two alternating HDR simulation buffers, independent of display resolution. A 160 × 120 grayscale intensity frame is sent to UDP port **4242** at up to 20 Hz; Python warps it into projector coordinates using the active calibration before sending it. Without calibration the whole camera frame maps to the screen, so calibrate for accurate placement. Each datagram is exactly 19,200 bytes; an external sender must also supply **projector-aligned**, row-major 8-bit intensity, not optical flow. Keep the existing JSON port 7000 available as well.

In the Water scene press **F3** for the motion image, heightfield, packet rate, FPS, grid size, and tuning controls. Press **Tab** to hide the dashboard if it covers the controls. With the debug panel open, use **0** for live camera, **1** for a single impulse, **2** for a moving point, **3** for multiple points, **4** for a continuous stroke, and **5** for no-motion decay. Press 1 again to generate another impulse. Test modes ignore camera disturbances until 0 is selected. The debug panel adjusts sensitivity, impulse, threshold, propagation, damping, maximum disturbance, colors, appearance, and the 128/256/512 grid; changing grid clears the simulation. These settings are session-only. An optional background texture can be supplied through the water scene's exported `background_texture` property. The simulation requires a renderer supporting HDR 2D (Forward+ or Mobile).

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

The additional JSON `frame_motion` datagram has `amount` (changed-pixel fraction from 0 to 1) and `points` (up to eight normalized `{"x", "y"}` boundary samples). Scenes may implement `on_frame_motion(amount, points)` and/or `set_motion_amount(amount)`; the latter returns to zero if updates stop. Water instead consumes the separate binary intensity stream. Both represent visual change, not contact or gestures.

## Tests

Run the camera-independent Python suite from the `cv_layer` directory:

```powershell
python -m unittest discover -s tests -v
```

Tests cover calibration geometry/transforms/profile compatibility/recovery, tracking identity and expiration, interaction lifecycle, remote config and control validation, player selection, scene confirmation, and mockable camera switching. Camera/projector alignment, real camera disconnect/reconnect, MediaPipe performance, and Godot rendering still require hardware or a running Godot instance for end-to-end validation.

To exercise Godot's interaction receiver, simulation parity, water, and spinner without hardware, run `godot --headless --path visual_layer --script res://tests/interaction_test.gd` (use the Godot console executable on Windows).

For GPU propagation, decay, simultaneous disturbances, binary UDP input, and presentation checks, run `godot --path visual_layer --fixed-fps 60 --disable-vsync --script res://tests/water_gpu_test.gd` with a working graphical display and Forward+ renderer. This test performs GPU readback for verification only; the running simulation does not.

For Python dependency and remote settings details, see [CONFIGURATION.md](./CONFIGURATION.md).
