import Foundation

// MARK: - CLI argument parsing

struct Config {
    var calibrate = false
    var calibrationFile: String
    var cameraIndex = 0
    var verbose = false

    static let defaultCalibrationPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/share/gazectl/calibration.json"
    }()

    init() {
        calibrationFile = Self.defaultCalibrationPath
    }
}

func printUsage() {
    print("""
    usage: gazectl [options]

    Head tracking display focus switcher for macOS + Aerospace.

    options:
      --calibrate            Force recalibration
      --calibration-file F   Path to calibration file
                             (default: ~/.local/share/gazectl/calibration.json)
      --camera N             Camera index (default: 0)
      --verbose              Print yaw angle continuously
      -h, --help             Show this help
    """)
}

func parseArgs() -> Config {
    var config = Config()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--calibrate":
            config.calibrate = true
        case "--calibration-file":
            guard !args.isEmpty else {
                print("  [error] --calibration-file requires a path")
                exit(1)
            }
            config.calibrationFile = args.removeFirst()
        case "--camera":
            guard !args.isEmpty, let idx = Int(args.removeFirst()) else {
                print("  [error] --camera requires an integer")
                exit(1)
            }
            config.cameraIndex = idx
        case "--verbose":
            config.verbose = true
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            print("  [error] Unknown argument: \(arg)")
            printUsage()
            exit(1)
        }
    }
    return config
}

// MARK: - Signal handling

var running = true

func handleSignal(_: Int32) {
    running = false
}

signal(SIGINT, handleSignal)
signal(SIGTERM, handleSignal)

// MARK: - Main

let config = parseArgs()

// 1. Check monitors
let monitors = AerospaceMonitor.listMonitors()
if monitors.count < 2 {
    print("  [error] Need at least 2 monitors. Found: \(monitors.count)")
    if monitors.isEmpty {
        print("  Is aerospace installed and running?")
    }
    exit(1)
}

// 2. Start face tracker
let faceTracker = FaceTracker()
do {
    try faceTracker.start(cameraIndex: config.cameraIndex)
} catch {
    print("  [error] Cannot open camera \(config.cameraIndex): \(error)")
    exit(1)
}

// Wait briefly for camera to initialize and frames to start arriving
Thread.sleep(forTimeInterval: 1.0)

// Check if camera is actually delivering frames
let initialFrames = faceTracker.frameCount
Thread.sleep(forTimeInterval: 1.0)
if faceTracker.frameCount == initialFrames {
    print("  [error] No frames received from camera.")
    print("  Check System Settings > Privacy & Security > Camera")
    print("  and ensure this app has camera access.")
    faceTracker.stop()
    exit(1)
}

// 3. Load or run calibration
var calibration: [String: Double]?
if !config.calibrate {
    calibration = Calibration.load(from: config.calibrationFile)
    if calibration != nil {
        print("  Loaded calibration from \(config.calibrationFile)")
    }
}

if calibration == nil {
    calibration = Calibration.run(faceTracker: faceTracker, monitors: monitors)
    Calibration.save(calibration!, to: config.calibrationFile)
}

let cal = calibration!

// 4. Print startup info
let sortedCal = cal.sorted { $0.value < $1.value }
let boundaryValues = Calibration.boundaries(from: cal)

print("\n  gazectl - Head Tracking Display Switcher")
print("  ==========================================")
print("  Monitors:")
for (idStr, yaw) in sortedCal {
    let name = monitors.first { String($0.id) == idStr }?.name ?? "?"
    print("    \(name): calibrated at \(String(format: "%+.1f", yaw))°")
}
print("  Boundaries: \(boundaryValues.map { String(format: "%+.1f°", $0) }.joined(separator: ", "))")
print("  Verbose: \(config.verbose)")
print("\n  Turn your head to switch display focus.")
print("  Press Ctrl+C to quit.\n")

// 5. Tracking loop
var currentMonitor = AerospaceMonitor.currentMonitor()

while running {
    if let yaw = faceTracker.latestYaw {
        let target = Calibration.targetMonitor(yaw: yaw, calibration: cal)

        if config.verbose {
            let targetName = monitors.first { $0.id == target }?.name ?? "?"
            print("  yaw: \(String(format: "%+6.1f", yaw))°  target=\(targetName)", terminator: "\r")
            fflush(stdout)
        }

        if target != currentMonitor {
            let name = monitors.first { $0.id == target }?.name ?? "?"
            AerospaceMonitor.focusMonitor(target)
            currentMonitor = target
            if config.verbose {
                print("\n  >> Focused: \(name)")
            }
        }
    }
    Thread.sleep(forTimeInterval: 0.033)
}

// Cleanup
faceTracker.stop()
print("\n  Stopped.")
exit(0)
