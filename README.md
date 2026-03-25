# gazectl

Head tracking display focus switcher for macOS + [Aerospace](https://github.com/nikitabobko/AerospaceWM).

Uses your webcam and Apple's Vision framework to detect which way your head is turned, then switches Aerospace monitor focus automatically.

## Install

```bash
npm i -g gazectl
```

Or run directly:

```bash
npx gazectl
```

Requires macOS 14+ and [Aerospace](https://github.com/nikitabobko/AerospaceWM).

## Usage

```bash
# First run — calibrates automatically
gazectl

# With verbose logging
gazectl --verbose

# Force recalibration
gazectl --calibrate
```

On first run, gazectl asks you to look at each monitor and press Enter. It samples your head angle for 2 seconds per monitor, then saves calibration to `~/.local/share/gazectl/calibration.json`.

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--calibrate` | off | Force recalibration |
| `--calibration-file` | `~/.local/share/gazectl/calibration.json` | Custom calibration path |
| `--camera` | 0 | Camera index |
| `--verbose` | off | Print yaw angle continuously |

## How it works

1. **Calibrate** — look at each monitor, gazectl records the yaw angle
2. **Track** — Apple Vision detects head yaw in real-time (~30fps)
3. **Switch** — when yaw crosses the midpoint between calibrated angles, fires `aerospace focus-monitor`

## Build from source

```bash
swift build -c release
cp .build/release/gazectl /usr/local/bin/gazectl
```

## License

MIT
