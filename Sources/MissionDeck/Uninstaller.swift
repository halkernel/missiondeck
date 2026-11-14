import AppKit
import ServiceManagement

/// Removes every trace of MissionDeck from this Mac, then quits.
///
/// Order matters. macOS can freeze the keyboard and mouse if an app loses its Accessibility
/// permission while its input hook is active, so:
///   1. the hook is removed first,
///   2. files and settings are removed and the result is shown (you can still click OK),
///   3. MissionDeck quits, and only then is the permission removed.
enum Uninstaller {
    static func run(engine: Engine) {
        NSApp.activate(ignoringOtherApps: true)

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Uninstall MissionDeck?"
        confirm.informativeText = """
        This will:
        • turn off Launch at Login
        • delete its settings and log files
        • move MissionDeck.app to the Trash
        • quit MissionDeck, then remove its Accessibility permission
        """
        confirm.addButton(withTitle: "Uninstall")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        // 1. Remove the keyboard/mouse hook before anything else.
        engine.stop()

        let bundleID = Bundle.main.bundleIdentifier ?? "com.local.MissionDeck"
        let fileManager = FileManager.default
        var problems: [String] = []

        // 2a. Launch at Login
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                problems.append("Turn it off in System Settings → General → Login Items.")
            }
        }

        // 2b. Settings, logs, caches
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        let library = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let leftovers = [
            "Logs/MissionDeck",
            "Caches/\(bundleID)",
            "Saved Application State/\(bundleID).savedState",
            "Preferences/\(bundleID).plist",
        ]
        for path in leftovers {
            let url = library.appendingPathComponent(path)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }

        // 2c. The app itself (a running app can be moved to the Trash safely)
        let appURL = Bundle.main.bundleURL
        if appURL.pathExtension == "app" {
            do {
                try fileManager.trashItem(at: appURL, resultingItemURL: nil)
            } catch {
                problems.append("Drag \(appURL.path) to the Trash.")
            }
        }

        // 2d. Report, while the keyboard and mouse are guaranteed to work.
        let done = NSAlert()
        if problems.isEmpty {
            done.messageText = "MissionDeck has been uninstalled"
            done.informativeText = "Click OK to quit. Its Accessibility permission is removed right after it quits."
        } else {
            done.messageText = "MissionDeck is almost uninstalled"
            done.informativeText = "Click OK to quit. A few things need to be done by hand:\n\n• "
                + problems.joined(separator: "\n• ")
        }
        done.runModal()

        // 3. Quit, and remove the permission one second later, once MissionDeck is gone.
        scheduleRevokeAfterQuit(bundleID: bundleID)
        NSApp.terminate(nil)
    }

    /// Starts a tiny independent helper that waits for MissionDeck to quit, then runs
    /// `tccutil reset All <bundle id>`. Nothing in MissionDeck is running when it happens.
    private static func scheduleRevokeAfterQuit(bundleID: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            // Wait (max 10 s) until our process has exited, then reset only our own permissions.
            "for i in $(seq 1 20); do kill -0 \"$1\" 2>/dev/null || break; sleep 0.5; done; sleep 1; /usr/bin/tccutil reset All \"$2\"",
            "missiondeck-uninstall", String(pid), bundleID,
        ]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try? helper.run()   // not waited on; it keeps running after we quit
    }
}
