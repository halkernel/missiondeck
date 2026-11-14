import CoreGraphics
import Foundation

/// Read-only view of the window server's own window list (no permission needed).
/// Accessibility sometimes keeps listing a window an app has merely hidden (Spotify does this
/// when you close its window); the window server knows whether it's really on screen.
enum WindowServer {
    struct Info {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let isOnScreen: Bool
    }

    /// Every normal (layer 0) window, on screen or not.
    static func allWindows() -> [Info] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap(info)
    }

    static func window(_ id: CGWindowID) -> Info? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { return nil }
        return list.compactMap(info).first { $0.id == id }
    }

    /// The window server's entry for an app's window with (nearly) this frame.
    static func match(pid: pid_t, frame: CGRect, in windows: [Info]) -> Info? {
        var best: Info?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for w in windows where w.pid == pid {
            let d = abs(w.bounds.minX - frame.minX) + abs(w.bounds.minY - frame.minY)
                  + abs(w.bounds.width - frame.width) + abs(w.bounds.height - frame.height)
            if d < bestDistance {
                bestDistance = d
                best = w
            }
        }
        return bestDistance <= 8 ? best : nil
    }

    private static func info(_ dict: [String: Any]) -> Info? {
        guard (dict[kCGWindowLayer as String] as? Int) == 0,
              let id = dict[kCGWindowNumber as String] as? CGWindowID,
              let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
        let onScreen = (dict[kCGWindowIsOnscreen as String] as? Bool) ?? false
        return Info(id: id, pid: pid, bounds: bounds, isOnScreen: onScreen)
    }
}
