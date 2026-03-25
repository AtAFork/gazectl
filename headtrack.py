#!/usr/bin/env python3
"""
headtrack - Head tracking display focus switcher for macOS + Aerospace.

Uses your webcam + MediaPipe FaceMesh to detect head yaw direction,
then calls `aerospace focus-monitor` to switch display focus.
"""

import subprocess
import time
import argparse
import signal
import sys

import cv2
import mediapipe as mp
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

# MediaPipe FaceMesh landmark indices for the 6 points above
LANDMARK_IDS = [1, 152, 263, 33, 287, 57]


def get_head_yaw(face_landmarks, frame_shape):
    """Compute head yaw angle (left/right rotation) from face landmarks."""
    h, w = frame_shape[:2]

    image_points = np.array([
        (face_landmarks[i].x * w, face_landmarks[i].y * h)
        for i in LANDMARK_IDS
    ], dtype=np.float64)

    focal_length = w
    center = (w / 2, h / 2)
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
    # Decompose to get yaw (rotation around Y axis)
    angles, _, _, _, _, _ = cv2.RGBDecomposeProjectionMatrix(
        np.hstack((rotation_mat, np.zeros((3, 1))))
    )
    # angles: [pitch, yaw, roll] in degrees
    # Note: camera mirrors left/right, so we negate yaw
    return -angles[1, 0]


def switch_monitor(monitor_id, current_monitor):
    """Focus a monitor via aerospace if not already focused."""
    if monitor_id == current_monitor:
        return current_monitor
    try:
        subprocess.run(
            ["aerospace", "focus-monitor", str(monitor_id)],
            capture_output=True, timeout=2,
        )
        return monitor_id
    except Exception as e:
        print(f"  [warn] aerospace switch failed: {e}")
        return current_monitor


def get_current_monitor():
    """Get the currently focused aerospace monitor ID."""
    try:
        result = subprocess.run(
            ["aerospace", "list-monitors", "--focused"],
            capture_output=True, text=True, timeout=2,
        )
        # Output like: "1 | Built-in Retina Display"
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
        "--left-monitor", type=int, default=None,
        help="Aerospace monitor ID for display on your left (auto-detected if omitted)",
    )
    parser.add_argument(
        "--right-monitor", type=int, default=None,
        help="Aerospace monitor ID for display on your right (auto-detected if omitted)",
    )
    parser.add_argument(
        "--threshold", type=float, default=12.0,
        help="Yaw angle threshold in degrees to trigger switch (default: 12)",
    )
    parser.add_argument(
        "--debounce", type=float, default=0.4,
        help="Seconds head must stay turned before switching (default: 0.4)",
    )
    parser.add_argument(
        "--camera", type=int, default=0,
        help="Camera index (default: 0)",
    )
    parser.add_argument(
        "--preview", action="store_true",
        help="Show camera preview window (useful for calibration)",
    )
    parser.add_argument(
        "--verbose", action="store_true",
        help="Print yaw angle continuously",
    )
    args = parser.parse_args()

    # Auto-detect monitors
    if args.left_monitor is None or args.right_monitor is None:
        try:
            result = subprocess.run(
                ["aerospace", "list-monitors"],
                capture_output=True, text=True, timeout=2,
            )
            monitors = []
            for line in result.stdout.strip().splitlines():
                parts = line.split("|")
                mid = int(parts[0].strip())
                name = parts[1].strip() if len(parts) > 1 else ""
                monitors.append((mid, name))

            if len(monitors) >= 2:
                # Assume external monitor is on the left (common setup)
                # Built-in display is usually the laptop in front/right
                builtin = next((m for m in monitors if "built-in" in m[1].lower()), None)
                external = next((m for m in monitors if "built-in" not in m[1].lower()), None)
                if builtin and external:
                    args.left_monitor = args.left_monitor or external[0]
                    args.right_monitor = args.right_monitor or builtin[0]
                    print(f"  Auto-detected: left={external[1]} (id {external[0]}), right={builtin[1]} (id {builtin[0]})")
                else:
                    args.left_monitor = args.left_monitor or monitors[0][0]
                    args.right_monitor = args.right_monitor or monitors[1][0]
            else:
                print("  [error] Need at least 2 monitors. Found:", len(monitors))
                sys.exit(1)
        except Exception as e:
            print(f"  [error] Failed to detect monitors: {e}")
            sys.exit(1)

    print(f"""
  headtrack - Head Tracking Display Switcher
  ==========================================
  Left monitor:  {args.left_monitor}
  Right monitor: {args.right_monitor}
  Threshold:     {args.threshold}°
  Debounce:      {args.debounce}s
  Camera:        {args.camera}
  Preview:       {args.preview}

  Turn your head left/right to switch display focus.
  Press Ctrl+C to quit.
""")

    # Init MediaPipe
    mp_face_mesh = mp.solutions.face_mesh
    face_mesh = mp_face_mesh.FaceMesh(
        max_num_faces=1,
        refine_landmarks=False,
        min_detection_confidence=0.7,
        min_tracking_confidence=0.7,
    )

    # Init camera
    cap = cv2.VideoCapture(args.camera)
    if not cap.isOpened():
        print("  [error] Cannot open camera", args.camera)
        sys.exit(1)

    # Lower resolution for speed
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    cap.set(cv2.CAP_PROP_FPS, 30)

    current_monitor = get_current_monitor()
    pending_target = None
    pending_since = 0.0

    def cleanup(*_):
        cap.release()
        if args.preview:
            cv2.destroyAllWindows()
        face_mesh.close()
        print("\n  Stopped.")
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    while True:
        ret, frame = cap.read()
        if not ret:
            continue

        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        results = face_mesh.process(rgb)

        yaw = None
        if results.multi_face_landmarks:
            landmarks = results.multi_face_landmarks[0].landmark
            yaw = get_head_yaw(landmarks, frame.shape)

        if yaw is not None:
            if args.verbose:
                direction = "LEFT" if yaw < -args.threshold else ("RIGHT" if yaw > args.threshold else "CENTER")
                print(f"  yaw: {yaw:+6.1f}°  [{direction}]", end="\r")

            # Determine target
            if yaw < -args.threshold:
                target = args.left_monitor
            elif yaw > args.threshold:
                target = args.right_monitor
            else:
                target = None
                pending_target = None

            # Debounce logic
            now = time.monotonic()
            if target is not None:
                if target != pending_target:
                    pending_target = target
                    pending_since = now
                elif now - pending_since >= args.debounce:
                    if target != current_monitor:
                        current_monitor = switch_monitor(target, current_monitor)
                        if not args.verbose:
                            print(f"  Switched to monitor {current_monitor}")
                        pending_target = None

            if args.preview:
                # Draw yaw indicator
                color = (0, 255, 0) if -args.threshold <= yaw <= args.threshold else (0, 0, 255)
                cv2.putText(frame, f"Yaw: {yaw:+.1f}", (10, 30),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.8, color, 2)
                bar_x = int(frame.shape[1] / 2 + yaw * 5)
                cv2.line(frame, (frame.shape[1] // 2, 50), (bar_x, 50), color, 4)

        if args.preview:
            cv2.imshow("headtrack", frame)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break
        else:
            # Small sleep to avoid busy-spinning without preview's waitKey
            time.sleep(0.005)

    cleanup()


if __name__ == "__main__":
    main()
