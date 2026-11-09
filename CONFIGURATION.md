# Configuration

## Desktop settings

`last_settings.json` stores the last selected camera index, tracker, smoothing mode, processing resolution, target frame rate, flip, image adjustments, and pointer visibility. Invalid or out-of-range values are replaced with safe defaults. Settings are written only when a value changes.

The processing resolution is a software resize after capture. The camera's reported source resolution is tracked separately and is part of calibration compatibility.

Frame differencing is controlled by `motion_enabled` (default `true`), `motion_threshold` (1–100, default 25), and `motion_min_percent` (0–20, default 1). These can also be changed in the **Frame Motion** section of the desktop panel. Higher thresholds reject weaker pixel changes; higher minimum percentages reject smaller changed regions. Changes in projected content or room lighting may be detected as motion. The signal runs alongside the selected tracker and is separate from the Motion tracker.

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

Use a private numeric PIN with 4–12 digits; the recommended length is at least six. A missing, invalid, or default `1234` PIN is replaced with a random six-digit PIN for that run and printed in the Python console. The `secret_key` field from older configurations is not trusted or reused; Flask session signatures use a fresh per-run secret. Sessions are HTTP-only and same-site, logins are rate-limited, and state-changing requests reject cross-origin `Origin` headers.

The remote is intended for a trusted private LAN; HTTP does not encrypt traffic. Do not expose port 5000 to the public internet. The displayed scene is the last scene confirmed by Godot, and a pending scene request is shown separately.

Player data is in `profiles.json`. Keep the file private when it contains personal names.

## Python dependencies

Install with `python -m pip install -r cv_layer/requirements.txt`. `opencv-contrib-python` provides the CSRT/KCF object-tracker APIs; do not install it alongside `opencv-python` in the same environment. MediaPipe is used only by the Hands mode; the other trackers do not require a physical camera for unit tests.
