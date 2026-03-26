import Foundation
import CoreGraphics
import AppKit

struct Monitor {
    let id: Int
    let name: String
}

enum MonitorTransition: CustomStringConvertible {
    case none
    case move
    case click
    case moveAndClick

    var requiresAction: Bool {
        self != .none
    }

    var appliesFocus: Bool {
        self == .click || self == .moveAndClick
    }

    var description: String {
        switch self {
        case .none: return ".none"
        case .move: return ".move"
        case .click: return ".click"
        case .moveAndClick: return ".moveAndClick"
        }
    }
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

    static func focusedMonitor() -> Int? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let pid = frontApp.processIdentifier

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let windowPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                  windowPID == pid,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &rect) else {
                continue
            }

            return monitorContaining(point: CGPoint(x: rect.midX, y: rect.midY))
        }

        return nil
    }

    static func transition(
        to id: Int,
        cursorMonitor: Int?
    ) -> MonitorTransition {
        let hasCursor = cursorMonitor == id

        if hasCursor {
            // Cursor already on target — check if frontmost app window is here
            let axFocused = focusedMonitor() == id
            return axFocused ? .none : .click
        } else {
            // Moving cursor cross-monitor — always click.
            // The old .move case (focused but cursor elsewhere) was unreliable:
            // clicking empty desktop doesn't change the focused app per AX API,
            // so "focused" was often stale. Always clicking is safe and reliable.
            return .moveAndClick
        }
    }

    static func focusMonitor(_ id: Int, transition: MonitorTransition, debug: Bool = false) {
        guard transition.requiresAction else { return }

        let displayID = CGDirectDisplayID(id)
        let bounds = CGDisplayBounds(displayID)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        if debug {
            let cursorBefore = CGEvent(source: nil)?.location ?? .zero
            CLI.debug("[EXEC] display=\(displayID) bounds=\(bounds) center=\(center) cursorBefore=\(cursorBefore) transition=\(transition)")
        }

        if transition == .move || transition == .moveAndClick {
            CGWarpMouseCursorPosition(center)
            if debug {
                let cursorAfterWarp = CGEvent(source: nil)?.location ?? .zero
                CLI.debug("[WARP] target=\(center) cursorAfterWarp=\(cursorAfterWarp)")
            }
        }

        if transition.appliesFocus {
            let clickPos = transition == .click
                ? CGEvent(source: nil)?.location ?? center
                : center
            let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clickPos, mouseButton: .left)
            let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clickPos, mouseButton: .left)

            if debug {
                CLI.debug("[CLICK] pos=\(clickPos) mouseDown=\(mouseDown != nil ? "ok" : "FAILED") mouseUp=\(mouseUp != nil ? "ok" : "FAILED")")
            }

            mouseDown?.post(tap: .cghidEventTap)
            mouseUp?.post(tap: .cghidEventTap)

            if debug {
                let cursorAfterClick = CGEvent(source: nil)?.location ?? .zero
                CLI.debug("[POST-CLICK] cursorAfterClick=\(cursorAfterClick)")
            }
        } else if debug {
            CLI.debug("[NO-CLICK] transition=\(transition) — appliesFocus=false")
        }
    }

    private static func monitorContaining(point: CGPoint) -> Int? {
        let maxDisplays: UInt32 = 16
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(maxDisplays, &displays, &displayCount) == .success else {
            return nil
        }

        for index in 0..<Int(displayCount) {
            let displayID = displays[index]
            if CGDisplayBounds(displayID).contains(point) {
                return Int(displayID)
            }
        }

        return nil
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
