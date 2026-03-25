# headtrack

Head tracking display focus switcher for macOS + [Aerospace](https://github.com/nikitabobko/AerospaceWM).

Uses your webcam + MediaPipe to detect which direction your head is turned, then automatically switches Aerospace monitor focus.

## Setup

```bash
cd ~/personal/code/headtrack
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Usage

```bash
# Basic - auto-detects monitors
python headtrack.py

# With camera preview (useful for calibration)
python headtrack.py --preview --verbose

# Custom monitor mapping
python headtrack.py --left-monitor 2 --right-monitor 1

# Tune sensitivity
python headtrack.py --threshold 15 --debounce 0.5
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--left-monitor` | auto | Aerospace monitor ID for left display |
| `--right-monitor` | auto | Aerospace monitor ID for right display |
| `--threshold` | 12.0 | Yaw angle (degrees) to trigger switch |
| `--debounce` | 0.4 | Seconds head must stay turned |
| `--camera` | 0 | Camera index |
| `--preview` | off | Show camera preview window |
| `--verbose` | off | Print yaw angle continuously |
