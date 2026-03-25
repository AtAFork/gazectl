import Foundation

enum AerospaceMonitor {
    struct Monitor {
        let id: Int
        let name: String
    }

    static func listMonitors() -> [Monitor] {
        guard let output = runAerospace(["list-monitors"]) else { return [] }
        var monitors: [Monitor] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard let idStr = parts.first,
                  let id = Int(idStr.trimmingCharacters(in: .whitespaces)) else { continue }
            let name = parts.count > 1
                ? String(parts[1]).trimmingCharacters(in: .whitespaces)
                : ""
            monitors.append(Monitor(id: id, name: name))
        }
        return monitors
    }

    static func currentMonitor() -> Int? {
        guard let output = runAerospace(["list-monitors", "--focused"]) else { return nil }
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "|", maxSplits: 1)
        guard let idStr = parts.first else { return nil }
        return Int(idStr.trimmingCharacters(in: .whitespaces))
    }

    static func focusMonitor(_ id: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["aerospace", "focus-monitor", String(id)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func runAerospace(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["aerospace"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
