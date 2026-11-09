# Configuration

## Desktop settings

`last_settings.json` stores the last selected camera index, tracker, smoothing mode, processing resolution, target frame rate, flip, image adjustments, and pointer visibility. Invalid or out-of-range values are replaced with safe defaults. Settings are written only when a value changes.

The processing resolution is a software resize after capture. The camera's reported source resolution is tracked separately and is part of calibration compatibility.

`desktop` in `last_settings.json` defaults to `false`; set it to `true` for a desktop window on the next start or change **desktop next start** in the remote Tracking section. `--desktop` and `--headless` override this saved preference for the current process and its remote restart. The Tk window is optional and closing it does not stop camera processing. Tracker-specific settings are stored under `tracker_parameters` and validated against the active tracker's controls. The main thread owns settings; saves are debounced and flushed during orderly shutdown.

Frame differencing is controlled by `motion_enabled` (default `true`), `motion_threshold` (1–100, default 25), and `motion_min_percent` (0–20, default 1). These can also be changed in the **Frame Motion** section of the desktop panel. Higher thresholds reject weaker pixel changes; higher minimum percentages reject smaller changed regions. Changes in projected content or room lighting may be detected as motion. The signal runs alongside the selected tracker and is separate from the Motion tracker.

`motion_delay_ms` selects the comparison age in milliseconds (50–1000, default 50). The most recent sampled frame at least that old is used, so the actual age depends on processing rate. No motion is emitted until enough history exists after a reset. Longer delays help detect slower movement but can extend motion after an object stops; the output update rate remains unchanged.

The preview dropdown is session-only: **Camera** shows tracking and calibration overlays, **Motion (camera)** shows the thresholded camera-space intensity, and **Motion (projected)** shows the stream mapped to the projector aspect ratio. Calibration selection temporarily forces the camera view. Projected preview is marked uncalibrated when no compatible profile is active.

For Water and Edge Reveal, the CV layer sends intensity frames over UDP port 4242 to the same host as the JSON bridge. The 19,200-byte L8 image is already warped into projector space if a compatible calibration is active; receivers must not apply calibration again. Without calibration it is normalized across the full camera frame. The square GPU simulation samples this image in normalized coordinates and stretches its output to the display. Edge Reveal uses boundaries of motion intensity, independent of the selected tracker, and microphone level affects echo brightness when available; it does not synthesize sound. In Water, F3 opens session-only GPU simulation, appearance, grid, and test controls; 0 restores live input. Use Forward+ or Mobile for HDR 2D and avoid exposing the unauthenticated UDP ports outside a trusted network.

## Calibration profiles

Profiles are stored in `cv_layer/calibration.json`. Version 2 uses this shape:

```json
{
  "version": 2,
  "profiles": [
    {
      "name": "Camera 0 640x480",
      "signature": {
        "camera_idx": 0,
        "source_size": [1280, 720],
        "processing_size": [640, 480],
        "flip_h": false
      },
      "target_size": [1920, 1080],
      "points": [[50, 40], [590, 40], [590, 440], [50, 440]],
      "matrix": [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    }
  ]
}
```

The matrix above is illustrative only; saved matrices are validated against the points and target size when loaded. The calibration UI creates profiles using the actual calculated transformation. Profiles with invalid geometry, non-finite/singular transforms, or a mismatched signature are not applied. Legacy files containing only a `matrix` are treated as unverified, not as a compatible camera profile.

## Web remote

`remote_config.json` accepts:

```json
{
  "pin": "replace-with-a-private-6-to-12-digit-pin",
  "port": 5000
}
```

Use a private numeric PIN with 4–12 digits; the recommended length is at least six. An explicitly configured `1234` is accepted, but is easy to guess and should only be used on a trusted private network. A missing or invalid PIN is replaced with a random six-digit PIN for that run and printed in the Python console. The `secret_key` field from older configurations is not trusted or reused; Flask session signatures use a fresh per-run secret. Sessions are HTTP-only and same-site, logins are rate-limited, and state-changing requests reject cross-origin `Origin` headers.

The remote is intended for a trusted private LAN; HTTP does not encrypt traffic. Do not expose port 5000 to the public internet. The displayed scene is the last scene confirmed by Godot, and a pending scene request is shown separately.

Player data is in `profiles.json`. Keep the file private when it contains personal names.

Environment presets are stored locally in the git-ignored `environment_presets.json`, independently of player profiles. They contain camera, processing, tracker and audio settings plus the camera signature associated with the saved setup. A preset does not overwrite calibration data: only a separately saved, validated calibration matching the active camera geometry can load. Godot audio telemetry must be available to save or load a preset. Requests are queued for the CV main thread; a camera or tracker that fails to initialize is not confirmed merely because a request was accepted.

Operator previews use the existing capture, are encoded by a shared worker only while requested, and are limited to 320 × 240 at up to 5 fps. Diagnostics offers lower browser refresh rates; previews and operator endpoints require the same PIN session as the remote. They do not open another camera. Microphone telemetry comes from Godot's existing audio input rather than a second capture; the input and mapped values are sent as numbers over the local Godot status channel, not as audio. “No input frames” can indicate a disconnected or muted device; silent samples cannot establish whether a device is muted.

## Python dependencies

Install with `python -m pip install -r cv_layer/requirements.txt`. `opencv-contrib-python` provides the CSRT/KCF object-tracker APIs; do not install it alongside `opencv-python` in the same environment. MediaPipe is used only by the Hands mode; the other trackers do not require a physical camera for unit tests.
