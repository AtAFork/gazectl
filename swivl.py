#!/usr/bin/env python3
"""
swivl - Head tracking display focus switcher for macOS + Aerospace.

Uses your webcam + MediaPipe Face Landmarker to detect head yaw direction,
then calls `aerospace focus-monitor` to switch display focus.

Calibration-based: on first run, you look at each monitor so the program
learns which yaw angle corresponds to which display.
"""

import json
import os
import subprocess
import time
import argparse
import signal
import sys
import threading

import cv2
import mediapipe as mp
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision
import numpy as np


# 3D model points for head pose estimation (generic face model)
MODEL_POINTS = np.array([
    (0.0, 0.0, 0.0),        # Nose tip
    (0.0, -330.0, -65.0),    # Chin
    (-225.0, 170.0, -135.0), # Left eye left corner
    (225.0, 170.0, -135.0),  # Right eye right corner
    (-150.0, -150.0, -125.0),# Left mouth corner
    (150.0, -150.0, -125.0), # Right mouth corner
], dtype=np.float64)

# MediaPipe Face Landmarker landmark indices for the 6 points above
LANDMARK_IDS = [1, 152, 263, 33, 287, 57]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SWIVL_DATA = os.environ.get("SWIVL_HOME", os.path.expanduser("~/.local/share/swivl"))
DEFAULT_CALIBRATION_PATH = os.path.join(SWIVL_DATA, "calibration.json")


def get_head_yaw(face_landmarks, frame_w, frame_h):
    """Compute head yaw angle (left/right rotation) from face landmarks."""
    image_points = np.array([
        (face_landmarks[i].x * frame_w, face_landmarks[i].y * frame_h)
        for i in LANDMARK_IDS
    ], dtype=np.float64)

    focal_length = frame_w
    center = (frame_w / 2, frame_h / 2)
    camera_matrix = np.array([
        [focal_length, 0, center[0]],
        [0, focal_length, center[1]],
        [0, 0, 1],
    ], dtype=np.float64)
    dist_coeffs = np.zeros((4, 1))

    success, rotation_vec, _ = cv2.solvePnP(
        MODEL_POINTS, image_points, camera_matrix, dist_coeffs,
        flags=cv2.SOLVEPNP_ITERATIVE,
    )
    if not success:
        return None

    rotation_mat, _ = cv2.Rodrigues(rotation_vec)
    angles, _, _, _, _, _ = cv2.RQDecomp3x3(rotation_mat)
    return -angles[1]


_last_frame_ts = 0

def sample_yaw(cap, landmarker, lock, latest_landmarks, duration=2.0):
    """Sample yaw values for `duration` seconds, return median."""
    global _last_frame_ts
    samples = []
    start = time.monotonic()
    frame_ts = max(_last_frame_ts, int(time.monotonic() * 1000))

    while time.monotonic() - start < duration:
        ret, frame = cap.read()
        if not ret:
            continue

        frame_ts += 33
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)

        try:
            landmarker.detect_async(mp_image, frame_ts)
        except Exception:
            pass

        time.sleep(0.03)

        with lock:
            landmarks = latest_landmarks[0]

        if landmarks is not None:
            h, w = frame.shape[:2]
            yaw = get_head_yaw(landmarks, w, h)
            if yaw is not None:
                samples.append(yaw)
                print(f"    sampling... yaw: {yaw:+.1f}° ({len(samples)} samples)", end="\r")

    print()
    _last_frame_ts = frame_ts
    if not samples:
        return None
    return float(np.median(samples))


def calibrate(cap, landmarker, lock, latest_landmarks, aero_monitors):
    """Interactive calibration: look at each monitor, record yaw."""
    print("\n  === Calibration ===")
    print(f"  Found {len(aero_monitors)} monitors:\n")
    for mid, name in aero_monitors:
        print(f"    [{mid}] {name}")

    calibration = {}
    print()

    for mid, name in aero_monitors:
        print(f"  Look at \"{name}\" and press Enter...", end="", flush=True)
        try:
            input()
        except (EOFError, KeyboardInterrupt):
            sys.exit(0)

        yaw = sample_yaw(cap, landmarker, lock, latest_landmarks)
        if yaw is None:
            print(f"    [error] No face detected. Try again.")
            # Retry once
            print(f"  Look at \"{name}\" and press Enter...", end="", flush=True)
            try:
                input()
            except (EOFError, KeyboardInterrupt):
                sys.exit(0)
            yaw = sample_yaw(cap, landmarker, lock, latest_landmarks)
            if yaw is None:
                print(f"    [error] Still no face detected. Skipping.")
                continue

        calibration[str(mid)] = yaw
        print(f"    {name}: {yaw:+.1f}°")

    if len(calibration) < 2:
        print("\n  [error] Need at least 2 calibrated monitors.")
        sys.exit(1)

    print("\n  Calibration complete:")
    for mid_str, yaw in sorted(calibration.items(), key=lambda x: x[1]):
        name = next((m[1] for m in aero_monitors if str(m[0]) == mid_str), "?")
        print(f"    {name} (id {mid_str}): {yaw:+.1f}°")

    return calibration


def save_calibration(path, data):
    """Save calibration data to JSON."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"  Saved calibration to {path}")


def load_calibration(path):
    """Load calibration data from JSON. Returns None if not found."""
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError):
        return None


def get_target_monitor(yaw, calibration):
    """Given current yaw and calibration data, return the target monitor ID.

    Sorts monitors by calibrated yaw, computes midpoint boundaries,
    and returns whichever zone the current yaw falls in.
    """
    # Sort by calibrated yaw value
    sorted_monitors = sorted(calibration.items(), key=lambda x: x[1])

    # If yaw is below the lowest calibrated value, pick the lowest monitor
    if yaw <= sorted_monitors[0][1]:
        return int(sorted_monitors[0][0])

    # If yaw is above the highest calibrated value, pick the highest monitor
    if yaw >= sorted_monitors[-1][1]:
        return int(sorted_monitors[-1][0])

    # Find which zone yaw falls in (midpoint boundaries)
    for i in range(len(sorted_monitors) - 1):
        mid_a = sorted_monitors[i]
        mid_b = sorted_monitors[i + 1]
        boundary = (mid_a[1] + mid_b[1]) / 2
        if yaw < boundary:
            return int(mid_a[0])

    return int(sorted_monitors[-1][0])


def get_current_monitor():
    """Get the currently focused aerospace monitor ID."""
    try:
        result = subprocess.run(
            ["aerospace", "list-monitors", "--focused"],
            capture_output=True, text=True, timeout=2,
        )
        line = result.stdout.strip()
        if line:
            return int(line.split("|")[0].strip())
    except Exception:
        pass
    return None


def main():
    parser = argparse.ArgumentParser(
        description="Head tracking display focus switcher"
    )
    parser.add_argument(
        "--calibrate", action="store_true",
        help="Force recalibration (even if a calibration file exists)",
    )
    parser.add_argument(
        "--calibration-file", type=str, default=DEFAULT_CALIBRATION_PATH,
        help=f"Path to calibration file (default: {DEFAULT_CALIBRATION_PATH})",
    )
    parser.add_argument(
        "--camera", type=int, default=0,
        help="Camera index (default: 0)",
    )
    parser.add_argument(
        "--preview", action="store_true",
        help="Show camera preview window (calibration only — steals focus from aerospace)",
    )
    parser.add_argument(
        "--verbose", action="store_true",
        help="Print yaw angle continuously",
    )
    args = parser.parse_args()

    # Fetch aerospace monitors
    try:
        result = subprocess.run(
            ["aerospace", "list-monitors"],
            capture_output=True, text=True, timeout=2,
        )
        aero_monitors = []
        for line in result.stdout.strip().splitlines():
            parts = line.split("|")
            mid = int(parts[0].strip())
            name = parts[1].strip() if len(parts) > 1 else ""
            aero_monitors.append((mid, name))
    except Exception as e:
        print(f"  [error] Failed to list monitors: {e}")
        sys.exit(1)

    if len(aero_monitors) < 2:
        print("  [error] Need at least 2 monitors. Found:", len(aero_monitors))
        sys.exit(1)

    # Init MediaPipe Face Landmarker — check script dir and data dir
    model_path = os.path.join(SCRIPT_DIR, "face_landmarker.task")
    if not os.path.exists(model_path):
        model_path = os.path.join(SWIVL_DATA, "face_landmarker.task")
    if not os.path.exists(model_path):
        print(f"  [error] Model file not found")
        print("  Run: swivl (the bin wrapper downloads it automatically)")
        sys.exit(1)

    latest_landmarks = [None]
    lock = threading.Lock()

    def on_result(result, image, timestamp_ms):
        with lock:
            if result.face_landmarks:
                latest_landmarks[0] = result.face_landmarks[0]
            else:
                latest_landmarks[0] = None

    base_options = mp_python.BaseOptions(model_asset_path=model_path)
    options = vision.FaceLandmarkerOptions(
        base_options=base_options,
        running_mode=vision.RunningMode.LIVE_STREAM,
        num_faces=1,
        min_face_detection_confidence=0.7,
        min_face_presence_confidence=0.7,
        min_tracking_confidence=0.7,
        result_callback=on_result,
    )
    landmarker = vision.FaceLandmarker.create_from_options(options)

    # Init camera
    cap = cv2.VideoCapture(args.camera)
    if not cap.isOpened():
        print("  [error] Cannot open camera", args.camera)
        sys.exit(1)

    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    cap.set(cv2.CAP_PROP_FPS, 30)

    # Load or run calibration
    calibration = None
    if not args.calibrate:
        calibration = load_calibration(args.calibration_file)
        if calibration:
            print(f"  Loaded calibration from {args.calibration_file}")

    if calibration is None:
        calibration = calibrate(cap, landmarker, lock, latest_landmarks, aero_monitors)
        save_calibration(args.calibration_file, calibration)

    # Print config
    sorted_cal = sorted(calibration.items(), key=lambda x: x[1])
    boundaries = []
    for i in range(len(sorted_cal) - 1):
        b = (sorted_cal[i][1] + sorted_cal[i + 1][1]) / 2
        boundaries.append(b)

    print(f"\n  headtrack - Head Tracking Display Switcher")
    print(f"  ==========================================")
    print(f"  Monitors:")
    for mid_str, yaw in sorted_cal:
        name = next((m[1] for m in aero_monitors if str(m[0]) == mid_str), "?")
        print(f"    {name}: calibrated at {yaw:+.1f}°")
    print(f"  Boundaries: {', '.join(f'{b:+.1f}°' for b in boundaries)}")
    print(f"  Preview: {args.preview}")
    print(f"\n  Turn your head to switch display focus.")
    print(f"  Press Ctrl+C to quit.\n")

    current_monitor = get_current_monitor()
    frame_ts = _last_frame_ts

    def cleanup(*_):
        cap.release()
        if args.preview:
            cv2.destroyAllWindows()
        landmarker.close()
        print("\n  Stopped.")
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    while True:
        ret, frame = cap.read()
        if not ret:
            continue

        frame_ts += 33
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)

        try:
            landmarker.detect_async(mp_image, frame_ts)
        except Exception:
            pass

        yaw = None
        with lock:
            landmarks = latest_landmarks[0]

        if landmarks is not None:
            h, w = frame.shape[:2]
            yaw = get_head_yaw(landmarks, w, h)

        if yaw is not None:
            target = get_target_monitor(yaw, calibration)

            if args.verbose:
                target_name = next((m[1] for m in aero_monitors if m[0] == target), "?")
                print(f"  yaw: {yaw:+6.1f}°  target={target_name}", end="\r")

            if target != current_monitor:
                name = next((m[1] for m in aero_monitors if m[0] == target), "?")
                subprocess.Popen(
                    ["aerospace", "focus-monitor", str(target)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                current_monitor = target
                if args.verbose:
                    print(f"\n  >> Focused: {name}")

            if args.preview:
                color = (0, 255, 0)
                cv2.putText(frame, f"Yaw: {yaw:+.1f}", (10, 30),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.8, color, 2)
                bar_x = int(frame.shape[1] / 2 + yaw * 5)
                cv2.line(frame, (frame.shape[1] // 2, 50), (bar_x, 50), color, 4)

        if args.preview:
            cv2.imshow("headtrack", frame)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break
        else:
            time.sleep(0.005)

    cleanup()


if __name__ == "__main__":
    main()
