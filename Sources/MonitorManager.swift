import Foundation
import CoreGraphics
import AppKit

struct Monitor {
    let id: Int
    let name: String
}

enum MonitorManager {
    static func listMonitors() -> [Monitor] {
        let maxDisplays: UInt32 = 16
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        let err = CGGetActiveDisplayList(maxDisplays, &displays, &displayCount)
        guard err == .success else { return [] }

        var monitors: [Monitor] = []
        for i in 0..<Int(displayCount) {
            let displayID = displays[i]
            let bounds = CGDisplayBounds(displayID)
            let name = screenName(for: displayID)
                ?? "\(Int(bounds.width))x\(Int(bounds.height))"
            monitors.append(Monitor(id: Int(displayID), name: name))
        }
        return monitors
    }

    static func currentMonitor() -> Int? {
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                return screenNumber.map { Int($0) }
            }
        }
        return nil
    }

    /// Focus a monitor by moving the cursor and/or clicking as needed.
    ///
    /// - `focusedMonitor`: the monitor macOS currently considers focused
    ///   (tracked by the caller based on gaze, NOT cursor position).
    static func focusMonitor(_ id: Int, focusedMonitor: Int?) {
        let cursorOn = currentMonitor()
        let alreadyFocused = focusedMonitor == id
        let cursorAlreadyThere = cursorOn == id

        // Case 4: already focused and cursor already there — nothing to do
        if alreadyFocused && cursorAlreadyThere { return }

        let displayID = CGDirectDisplayID(id)
        let bounds = CGDisplayBounds(displayID)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // Cases 1 & 3: cursor is on the wrong monitor — move it
        if !cursorAlreadyThere {
            CGWarpMouseCursorPosition(center)
        }

        // Cases 1 & 2: monitor isn't focused — click to focus
        if !alreadyFocused {
            // If cursor was already on the target, click where it is (don't move it).
            // CGEvent uses top-left origin coordinates.
            let clickPos = cursorAlreadyThere
                ? CGEvent(source: nil)?.location ?? center
                : center
            let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clickPos, mouseButton: .left)
            let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clickPos, mouseButton: .left)
            mouseDown?.post(tap: .cghidEventTap)
            mouseUp?.post(tap: .cghidEventTap)
        }
    }

    private static func screenName(for displayID: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            if screenNumber == displayID {
                return screen.localizedName
            }
        }
        return nil
    }
}
