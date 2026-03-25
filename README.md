# swivl

Head tracking display focus switcher for macOS + [Aerospace](https://github.com/nikitabobko/AerospaceWM).

Uses your webcam and MediaPipe to detect which way your head is turned, then switches Aerospace monitor focus automatically.

## Install

```bash
npm i -g swivl
```

Or run directly:

```bash
npx swivl
```

Requires Python 3.9+ and [Aerospace](https://github.com/nikitabobko/AerospaceWM). First run sets up a Python venv and downloads the MediaPipe model automatically.

## Usage

```bash
# First run — calibrates automatically
swivl

# With verbose logging
swivl --verbose

# Force recalibration
swivl --calibrate
```

On first run, swivl asks you to look at each monitor and press Enter. It samples your head angle for 2 seconds per monitor, then saves calibration to `~/.local/share/swivl/calibration.json`.

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--calibrate` | off | Force recalibration |
| `--calibration-file` | `~/.local/share/swivl/calibration.json` | Custom calibration path |
| `--camera` | 0 | Camera index |
| `--preview` | off | Show camera preview (steals focus — calibration only) |
| `--verbose` | off | Print yaw angle continuously |

## How it works

1. **Calibrate** — look at each monitor, swivl records the yaw angle
2. **Track** — MediaPipe Face Landmarker detects head yaw in real-time (~30fps)
3. **Switch** — when yaw crosses the midpoint between calibrated angles, fires `aerospace focus-monitor`

## License

MIT
