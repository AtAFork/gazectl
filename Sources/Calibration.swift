import Foundation

enum Calibration {
    // MARK: - Persistence

    static func load(from path: String) -> [String: Double]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                CLI.warning("Calibration file is corrupt, will recalibrate")
                return nil
            }
            var result: [String: Double] = [:]
            for (key, value) in dict {
                if let d = value as? Double {
                    result[key] = d
                } else if let n = value as? NSNumber {
                    result[key] = n.doubleValue
                }
            }
            return result.isEmpty ? nil : result
        } catch {
            CLI.warning("Cannot read calibration file: \(error.localizedDescription)")
            return nil
        }
    }

    static func save(_ calibration: [String: Double], to path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        do {
            let data = try JSONSerialization.data(
                withJSONObject: calibration, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: URL(fileURLWithPath: path))
            CLI.success("Saved calibration")
        } catch {
            CLI.error("Failed to save calibration: \(error)")
        }
    }

    // MARK: - Sampling

    static func sampleYaw(faceTracker: FaceTracker, duration: TimeInterval = 2.0) -> Double? {
        var samples: [Double] = []
        let start = Date()
        let expectedSamples = Int(duration / 0.033)

        while Date().timeIntervalSince(start) < duration {
            if let yaw = faceTracker.latestYaw {
                samples.append(yaw)
                CLI.printSamplingProgress(
                    yaw: yaw,
                    sampleCount: samples.count,
                    totalSamples: expectedSamples
                )
            }
            Thread.sleep(forTimeInterval: 0.033)
        }
        // Clear the progress line
        print("\(Style.clearLine)\r", terminator: "")
        fflush(stdout)

        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Interactive calibration

    static func run(
        faceTracker: FaceTracker,
        monitors: [Monitor]
    ) -> [String: Double]? {
        CLI.printCalibrationHeader(monitorCount: monitors.count)

        var calibration: [String: Double] = [:]

        for (index, m) in monitors.enumerated() {
            CLI.printCalibrationPrompt(m.name, step: index + 1, total: monitors.count)
            guard readLine() != nil else { return nil }

            var yaw = sampleYaw(faceTracker: faceTracker)
            if yaw == nil {
                CLI.warning("No face detected. Try again.")
                CLI.printCalibrationPrompt(m.name, step: index + 1, total: monitors.count)
                guard readLine() != nil else { return nil }
                yaw = sampleYaw(faceTracker: faceTracker)
                if yaw == nil {
                    CLI.error("Still no face detected. Skipping.")
                    continue
                }
            }

            calibration[String(m.id)] = yaw!
            CLI.printCalibrationResult(m.name, yaw: yaw!)
        }

        if calibration.count < 2 {
            CLI.error("Need at least 2 calibrated monitors.")
            exit(1)
        }

        let sorted = calibration.sorted { $0.value < $1.value }
        let entries: [(name: String, yaw: Double)] = sorted.map { idStr, yaw in
            let name = monitors.first { String($0.id) == idStr }?.name ?? "?"
            return (name: name, yaw: yaw)
        }
        CLI.printCalibrationSummary(entries)

        return calibration
    }

    // MARK: - Target monitor selection

    /// Fraction of the gap between adjacent monitors used as hysteresis on each
    /// side of the midpoint.  A value of 0.15 means you must cross 15% past the
    /// midpoint before switching, creating a 30% dead-zone that prevents flicker.
    private static let hysteresis = 0.15

    static func targetMonitor(yaw: Double, calibration: [String: Double], currentMonitor: Int = 0) -> Int {
        let sorted = calibration.sorted { $0.value < $1.value }

        guard let first = sorted.first, let last = sorted.last else { return 0 }

        if yaw <= first.value {
            return Int(first.key) ?? 0
        }
        if yaw >= last.value {
            return Int(last.key) ?? 0
        }

        let currentKey = String(currentMonitor)

        for i in 0..<(sorted.count - 1) {
            let midpoint = (sorted[i].value + sorted[i + 1].value) / 2.0
            let margin  = (sorted[i + 1].value - sorted[i].value) * hysteresis

            // Shift the boundary away from whichever adjacent monitor we're on,
            // so the user has to look further before a switch triggers.
            let boundary: Double
            if currentKey == sorted[i].key {
                boundary = midpoint + margin   // harder to leave left monitor
            } else if currentKey == sorted[i + 1].key {
                boundary = midpoint - margin   // harder to leave right monitor
            } else {
                boundary = midpoint
            }

            if yaw < boundary {
                return Int(sorted[i].key) ?? 0
            }
        }

        return Int(last.key) ?? 0
    }

    static func boundaries(from calibration: [String: Double]) -> [Double] {
        let sorted = calibration.sorted { $0.value < $1.value }
        var result: [Double] = []
        for i in 0..<(sorted.count - 1) {
            result.append((sorted[i].value + sorted[i + 1].value) / 2.0)
        }
        return result
    }
}
