import AppKit
import ApplicationServices

enum WindowAction {
    case close, minimize, hide, quit
}

enum WindowActions {
    /// Accessibility calls into other apps can block, so they run off the main thread.
    private static let queue = DispatchQueue(label: "MissionDeck.actions", qos: .userInitiated)

    /// Calls completion(true) only once the result is confirmed: the window is really gone,
    /// minimized, the app hidden or quit. completion(false) means it didn't happen.
    static func perform(_ action: WindowAction, on target: WindowTarget, completion: @escaping (Bool) -> Void) {
        queue.async {
            let succeeded: Bool
            switch action {
            case .close:    succeeded = close(target)
            case .minimize: succeeded = minimize(target)
            case .hide:     succeeded = hide(target)
            case .quit:     succeeded = quit(target)
            }
            DispatchQueue.main.async { completion(succeeded) }
        }
    }

    // MARK: - Actions

    private static func close(_ target: WindowTarget) -> Bool {
        AXUIElementSetMessagingTimeout(target.window, 0.3)
        let tracked = trackedWindow(target)

        // 1. Press the window's own close button.
        if let closeButton = AX.element(target.window, kAXCloseButtonAttribute) {
            _ = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            if waitUntil(seconds: 0.8, { windowIsGone(target, tracked) }) {
                log(target, "close button → closed")
                return true
            }
        }

        // 2. Spotify, Electron and other web-based apps often ignore an outside close request
        //    while in the background. Send ⌘W to that app instead.
        if focusWithinApp(target) {
            sendCommandShortcut("w", keyCode: 13, to: target.pid)
            if waitUntil(seconds: 1.2, { windowIsGone(target, tracked) }) {
                log(target, "⌘W → closed")
                return true
            }
        }

        // 3. Single-window apps that keep running after their window closes (Spotify, music
        //    players, chat apps): hiding the app is exactly what their own close button does.
        if appWindowCount(target.pid) <= 1 {
            DispatchQueue.main.sync { _ = NSRunningApplication(processIdentifier: target.pid)?.hide() }
            let app = AXUIElementCreateApplication(target.pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            if waitUntil(seconds: 1.0, { AX.bool(app, kAXHiddenAttribute) == true || windowIsGone(target, tracked) }) {
                log(target, "single-window app → hidden")
                return true
            }
        }

        log(target, "FAILED (app refused every method)")
        return false
    }

    private static func minimize(_ target: WindowTarget) -> Bool {
        AXUIElementSetMessagingTimeout(target.window, 0.3)
        _ = AXUIElementSetAttributeValue(target.window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        if waitUntil(seconds: 0.8, { isMinimized(target) || windowIsGone(target, nil) }) { return true }
        guard focusWithinApp(target) else { return false }
        sendCommandShortcut("m", keyCode: 46, to: target.pid)
        return waitUntil(seconds: 1.2, { isMinimized(target) || windowIsGone(target, nil) })
    }

    private static func hide(_ target: WindowTarget) -> Bool {
        DispatchQueue.main.async {
            _ = NSRunningApplication(processIdentifier: target.pid)?.hide()
        }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        return waitUntil(seconds: 1.0, { AX.bool(app, kAXHiddenAttribute) == true || !processIsAlive(target.pid) })
    }

    private static func quit(_ target: WindowTarget) -> Bool {
        DispatchQueue.main.async {
            _ = NSRunningApplication(processIdentifier: target.pid)?.terminate()
        }
        // An app may ask "Save changes?" first; then it is still running and we report that.
        return waitUntil(seconds: 2.5, { !processIsAlive(target.pid) })
    }

    // MARK: - Checks

    /// The window server's id for this window, if it is on screen right now.
    private static func trackedWindow(_ target: WindowTarget) -> CGWindowID? {
        guard let info = WindowServer.match(pid: target.pid, frame: target.frame, in: WindowServer.allWindows()),
              info.isOnScreen else { return nil }
        return info.id
    }

    private static func windowIsGone(_ target: WindowTarget, _ tracked: CGWindowID?) -> Bool {
        guard processIsAlive(target.pid) else { return true }

        // The window server is the most reliable: it knows when a window was hidden, not destroyed.
        if let id = tracked {
            guard let info = WindowServer.window(id) else { return true }   // destroyed
            if !info.isOnScreen { return true }                                // hidden (Spotify)
        }

        // A closed window's accessibility element becomes invalid.
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(target.window, kAXRoleAttribute as CFString, &role) == .invalidUIElement {
            return true
        }
        // Or it is simply no longer in the app's window list.
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let windows = AX.elements(app, kAXWindowsAttribute) else { return false }
        return !windows.contains { CFEqual($0, target.window) }
    }

    private static func appWindowCount(_ pid: pid_t) -> Int {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let windows = AX.elements(app, kAXWindowsAttribute) ?? []
        return windows.filter { AX.role($0) == kAXWindowRole && AX.bool($0, kAXMinimizedAttribute) != true }.count
    }

    private static func isMinimized(_ target: WindowTarget) -> Bool {
        AX.bool(target.window, kAXMinimizedAttribute) == true
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(60_000)
        }
        return condition()
    }

    // MARK: - Troubleshooting log (memory only, last 20 entries, app names only)

    private static var entries: [String] = []

    /// Called on `queue`.
    private static func log(_ target: WindowTarget, _ result: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        entries.append("\(time)  \(target.appName): \(result)")
        if entries.count > 20 { entries.removeFirst(entries.count - 20) }
    }

    static func recentLog() -> String {
        let lines = queue.sync { entries }
        return lines.isEmpty ? "(none yet)\n" : lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Keyboard fallback

    /// Makes the target the front window *inside its own app* (without switching apps,
    /// so Mission Control stays open). Returns false if we can't be sure a shortcut
    /// would reach this exact window, so we never close the wrong one.
    private static func focusWithinApp(_ target: WindowTarget) -> Bool {
        _ = AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(target.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        usleep(100_000)
        if AX.bool(target.window, kAXMainAttribute) == true { return true }

        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        return (AX.elements(app, kAXWindowsAttribute)?.count ?? 0) == 1
    }

    /// Sends ⌘<letter> straight to one app. The letter is set explicitly so it works on any keyboard layout.
    private static func sendCommandShortcut(_ letter: String, keyCode: CGKeyCode, to pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        let characters = Array(letter.utf16)
        for event in [down, up] {
            event.flags = .maskCommand
            event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
            event.setIntegerValueField(.eventSourceUserData, value: Engine.syntheticTag)
        }
        down.postToPid(pid)
        usleep(20_000)
        up.postToPid(pid)
    }
}

/// Opens or closes Mission Control, exactly like pressing the Mission Control key.
/// Used to make Mission Control redraw after a window is gone, so no "ghost" stays behind.
enum MissionControlToggle {
    private static let locations = [
        "/System/Applications/Mission Control.app",
        "/Applications/Mission Control.app",
    ]

    static func toggle() {
        guard let path = locations.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true   // it's a tiny launcher; run it again each time
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration, completionHandler: nil)
    }
}
