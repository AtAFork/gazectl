import Foundation

enum Calibration {
    // MARK: - Persistence

    static func load(from path: String) -> [String: Double]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
            print("  Saved calibration to \(path)")
        } catch {
            print("  [error] Failed to save calibration: \(error)")
        }
    }

    // MARK: - Sampling

    static func sampleYaw(faceTracker: FaceTracker, duration: TimeInterval = 2.0) -> Double? {
        var samples: [Double] = []
        let start = Date()
        while Date().timeIntervalSince(start) < duration {
            if let yaw = faceTracker.latestYaw {
                samples.append(yaw)
                print("    sampling... yaw: \(String(format: "%+.1f", yaw))° (\(samples.count) samples)", terminator: "\r")
                fflush(stdout)
            }
            Thread.sleep(forTimeInterval: 0.033)
        }
        print()
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Interactive calibration

    static func run(
        faceTracker: FaceTracker,
        monitors: [AerospaceMonitor.Monitor]
    ) -> [String: Double] {
        print("\n  === Calibration ===")
        print("  Found \(monitors.count) monitors:\n")
        for m in monitors {
            print("    [\(m.id)] \(m.name)")
        }

        var calibration: [String: Double] = [:]
        print()

        for m in monitors {
            print("  Look at \"\(m.name)\" and press Enter...", terminator: "")
            fflush(stdout)
            _ = readLine()

            var yaw = sampleYaw(faceTracker: faceTracker)
            if yaw == nil {
                print("    [error] No face detected. Try again.")
                print("  Look at \"\(m.name)\" and press Enter...", terminator: "")
                fflush(stdout)
                _ = readLine()
                yaw = sampleYaw(faceTracker: faceTracker)
                if yaw == nil {
                    print("    [error] Still no face detected. Skipping.")
                    continue
                }
            }

            calibration[String(m.id)] = yaw!
            print("    \(m.name): \(String(format: "%+.1f", yaw!))°")
        }

        if calibration.count < 2 {
            print("\n  [error] Need at least 2 calibrated monitors.")
            exit(1)
        }

        print("\n  Calibration complete:")
        let sorted = calibration.sorted { $0.value < $1.value }
        for (idStr, yaw) in sorted {
            let name = monitors.first { String($0.id) == idStr }?.name ?? "?"
            print("    \(name) (id \(idStr)): \(String(format: "%+.1f", yaw))°")
        }

        return calibration
    }

    // MARK: - Target monitor selection

    static func targetMonitor(yaw: Double, calibration: [String: Double]) -> Int {
        let sorted = calibration.sorted { $0.value < $1.value }

        guard let first = sorted.first, let last = sorted.last else { return 0 }

        if yaw <= first.value {
            return Int(first.key) ?? 0
        }
        if yaw >= last.value {
            return Int(last.key) ?? 0
        }

        for i in 0..<(sorted.count - 1) {
            let boundary = (sorted[i].value + sorted[i + 1].value) / 2.0
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
