# LightTable

LightTable is a portable interactive projection system. The Python/OpenCV layer captures and tracks camera input, maps it through a validated surface calibration, then sends normalized JSON interaction events over UDP to the Godot 4 visual layer.

## Project layout

- `cv_layer/` — Python capture loop, six trackers, calibration, tracking lifecycle, Tkinter controls, and LAN remote.
- `visual_layer/` — Godot project, UDP receiver, cursor layer, and interactive scenes.
- `profiles.json` — player profiles managed by the web remote.
- `last_settings.json` — last-used camera, tracker, image, and smoothing controls.
- `environment_presets.json` — locally saved operator environment settings.
- `remote_config.json` — web remote PIN and port. See [CONFIGURATION.md](./CONFIGURATION.md).
- `cv_layer/calibration.json` — camera-specific calibration profiles, created when a profile is saved.

## Start

1. Install Python 3.9+ and Godot 4.x.
2. Install the CV dependencies: `python -m pip install -r cv_layer/requirements.txt`.
3. Launch `visual_layer/project.godot` in Godot.
4. Run `python cv_layer/main.py` from the repository root, or use `start.bat`. The CV layer defaults to **headless**, with no Tkinter window. Use `python cv_layer/main.py --desktop` or `start.bat --desktop` to show the desktop controls; `--headless` explicitly selects headless mode.
5. Connect a phone to the same LAN and open the URL printed by the Python process. A generated one-run PIN is printed on startup when no valid PIN is configured.

OpenCV camera capture can fail temporarily without terminating the application; it retries the selected camera while the remote remains available. If OpenCV repeatedly reports that a camera index is out of range, select the correct **camera** index in the remote's **Settings → Tracking** section or the desktop panel. Calibration is only restored when the camera configuration matches. Closing the optional desktop window leaves the CV layer running. Use **Settings → Preferences → Stop CV and remote** or **Restart CV and remote** in the authenticated remote, or Ctrl+C in the CV console. These actions do not stop Godot. The Windows launcher opens a separate **LightTable_CV** console and leaves it running when Godot exits; Ctrl+C in the original launcher prompt does not stop that console. The virtual interaction simulator can be run separately with `python cv_layer/simulate_hands.py`; it does not require a physical camera.

The saved `desktop` boolean in `last_settings.json` controls the default when no mode flag is supplied; the remote **desktop next start** setting changes it. An explicit command-line mode takes precedence, including after a remote restart. Existing settings remain compatible and are saved after changes settle. Godot, not the Python CV process, owns microphone capture and audio processing.

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

Use the **Calibration** section in the remote or optional desktop panel:

1. Select the camera, processing resolution, and horizontal-flip setting you will use.
2. Choose **Start**, then click the projected region in the live preview in order: top-left, top-right, bottom-right, bottom-left.
3. Correct a selection with **Undo**. **Cancel** restores the previous valid transform; **Reset** clears the active transform.
4. Choose **Save** to persist the validated profile. Profiles are keyed by camera index, source and processing resolutions, and horizontal flip.

Only a profile matching the current camera configuration is applied. Existing matrix-only calibration files do not contain enough information to verify compatibility and are deliberately not auto-applied; recalibrate and save a profile instead. Resolution, camera, or flip changes clear the active transform unless a matching saved profile is available.

## Operator remote

After signing in, use **Play** for scenes and players. The gear opens **Settings**, with **Tracking** for the tracker selector, camera, image, motion, and tracker-specific controls; **Calibration** for corner selection; **Diagnostics** for status and microphone monitoring; and **Preferences** for environment presets and process controls. Changes are shared with the desktop interface. Tracker-specific controls are rebuilt for the active tracker; an unavailable camera or tracker may not switch successfully.

In **Settings → Tracking** select adjusted camera, tracking overlay, or thresholded motion intensity. Previews reuse the active capture and are encoded once for all viewers, on demand, at up to 320 × 240 and 5 fps; choose 2 or 1 fps on a slower connection. Stop viewing or switch sections to stop requesting frames. In **Settings → Calibration**, select **Start**, tap the four corners in order on the camera overlay, then **Save**. **Undo**, **Cancel**, **Reset**, and loading a compatible saved profile are also available. A stale camera-configuration preview cannot submit points.

For the Object tracker, use **Settings → Tracking → Select object** and tap the top-left and bottom-right corners on the adjusted camera preview; the selection is initialized on the next captured frame. **Clear objects** removes tracked objects. In desktop mode the existing `a` and `x` shortcuts remain available.

The microphone meters show Godot's measured input and its actual smoothed, floor/ceiling-mapped scene level. Yellow markers show the floor and ceiling on the input meter; adjust them while making sound. “No input frames” or “unavailable” is not a measured zero. Silence and a muted microphone cannot always be distinguished from samples alone. Godot must be running on the same host as the CV layer for the local audio telemetry.

Use **Settings → Save current** to name a preset; load, rename, and delete it there. Presets include the active tracking parameters and confirmed Godot audio range. Saving or loading requires current Godot telemetry. They record camera configuration, but do not copy or force calibration: the normal calibration system loads a saved profile only when camera index, source and processing resolution, and flip match. Select a compatible calibration profile or recalibrate if the setup changes.

The remote is intended for a trusted private LAN: previews and controls require login, but HTTP is not encrypted. A short PIN such as `1234` is easy to guess. See [CONFIGURATION.md](./CONFIGURATION.md) for security and persistence details.

## Synthetic performance check

Run `python cv_layer/benchmark_operator.py` and repeat with `--preview`, `--desktop`, and `--desktop --preview`. This runs synthetic 640 × 480 frames through Edge tracking and frame motion at a 30 fps target, without a camera, Flask, Godot, or audio. `cpu_percent_one_core` is process CPU time divided by wall time (100% means one core); the Windows memory number is the process working set. `processing_fps` measures the `process_frame` section only, while `fps` includes the 30 fps pacing.

One 8-second run per configuration on the development Windows laptop produced:

| Mode | Preview | CPU, one core | Working set | Processing FPS | Paced FPS |
| --- | --- | ---: | ---: | ---: | ---: |
| Headless | Off | 45.51% | 101.59 MiB | 372.70 | 29.38 |
| Headless | Web overlay | 41.99% | 104.76 MiB | 340.19 | 29.38 |
| Desktop | Off | 74.66% | 112.50 MiB | 273.37 | 28.70 |
| Desktop | On | 86.33% | 121.88 MiB | 188.50 | 27.75 |

These are short synthetic observations, not a mini-PC or full-system benchmark; CPU variation explains why the headless preview sample is lower than the no-preview sample. Actual camera capture, MediaPipe, UDP, audio, browser clients, and Godot can change the results. Remaining per-frame work includes tracker and frame-difference analysis, interaction association, UDP output, and operator status snapshots; JPEG encoding is skipped when no preview is requested.

## Tracking and interaction contract

All six existing modes remain selectable: MediaPipe Hands, Blob, Motion, Color, Edge, and Object. Tracker outputs are associated by proximity into stable runtime IDs; timestamped histories expire after temporary loss, and smoothing is applied after identity association. EMA is initialized at the first measurement; Kalman transition timing uses elapsed time.

For MediaPipe Hands, use **Target Mode** in the CV panel: `0` follows the palm, `1` follows the palm and switches to the index fingertip after a pointing pose is stable for three frames, `2` always follows the index fingertip, and `3` uses all five fingertips as separate scene pointers. Start with `2` to compare with mouse simulation; use `3` for multi-finger scenes. Five pointers per hand can activate multiple things at once and may be less stable when hands overlap. The preview marks selected targets with green crosses. The Godot hand skeleton and landmark dots are shown by default; press `Y` to toggle them. These landmarks do not establish physical surface contact.

Mouse simulation and camera points use the same scene interaction path. Turn off **Mouse Simulation** in Godot when testing the camera so the mouse does not leave an extra pointer. Calibrate for accurate positioning. Water and Edge Reveal are deliberately different: they respond to frame-difference motion, not hand points or the simulated mouse.

**Frame Motion** runs independently of the selected tracker. It compares downscaled camera frames, measures changed pixels, and sends motion-boundary points for other scenes and a separate intensity image for Water and Edge Reveal. The spinner can use overall motion energy even without a hand pointer. In the CV panel, enable/disable frame differencing, raise **Threshold** to reject small brightness changes, and raise **Min area %** to reject small moving regions. **Delay ms** selects how far back to compare (50–1000 ms, default 50); it does not slow the stream. A longer delay can reveal slow movement but also leaves a response for longer after movement stops. When calibrated, analysis is restricted to the calibrated surface. Changing projector imagery, lighting, or camera movement can still produce false motion; tune the controls for the installation.

The dropdown beneath the CV preview selects **Camera**, **Motion (camera)**, or **Motion (projected)**. The last view shows the projector-aligned intensity image sent to Godot, with the projector's aspect ratio. It is labeled uncalibrated if no compatible profile is active. During corner selection the preview temporarily returns to the camera image so clicks remain accurate. These preview choices last for the current session.

## Interactive water

The Water scene uses a GPU heightfield with two alternating HDR simulation buffers, independent of display resolution. A 160 × 120 grayscale intensity frame is sent to UDP port **4242** at up to 20 Hz; Python warps it into projector coordinates using the active calibration before sending it. The square simulation grid samples that image in normalized projector coordinates, and its output is displayed across the projector viewport; calibration is not applied twice. Without calibration the whole camera frame maps to the screen, so calibrate for accurate placement. Each datagram is exactly 19,200 bytes; an external sender must also supply **projector-aligned**, row-major 8-bit intensity, not optical flow. Keep the existing JSON port 7000 available as well.

In the Water scene press **F3** for the motion image, heightfield, packet rate, FPS, grid size, and tuning controls. Press **Tab** to hide the dashboard if it covers the controls. With the debug panel open, use **0** for live camera, **1** for a single impulse, **2** for a moving point, **3** for multiple points, **4** for a continuous stroke, and **5** for no-motion decay. Press 1 again to generate another impulse. Test modes ignore camera disturbances until 0 is selected. The debug panel adjusts sensitivity, impulse, threshold, propagation, damping, maximum disturbance, colors, appearance, and the 128/256/512 grid; changing grid clears the simulation. These settings are session-only. An optional background texture can be supplied through the water scene's exported `background_texture` property. The simulation requires a renderer supporting HDR 2D (Forward+ or Mobile).

**Edge Reveal** uses the same calibrated motion stream to draw colorful moving boundaries and GPU wave echoes spreading outward. It responds to boundaries of changing pixels, not the Edge tracker's static Canny image or centroid points, and works with any tracker selected. Enable Frame Motion to use it. If microphone input is available, sound makes the echoes brighter; the scene does not generate sound. The `Y` hand-skeleton overlay remains independent.

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
