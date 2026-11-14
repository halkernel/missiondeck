import AppKit

final class AppDelegate: NSObject {
    let engine = Engine()
    private var menuBar: MenuBarController?
    private var permissionTimer: Timer?
    fileprivate var startAttempts = 0
}

extension AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(engine: engine, requestAccess: { [weak self] in
            self?.requestAccessibility()
        })
        // If the permission is removed while running, the engine has already removed its hook;
        // quietly wait for it to come back (no dialog, so nothing pops up mid-uninstall).
        engine.onPermissionLost = { [weak self] in
            self?.startAttempts = 0
            self?.waitForPermission()
        }

        if AX.isTrusted {
            startEngine()
        } else {
            requestAccessibility()
        }
    }
}

extension AppDelegate {
    /// Explains why Accessibility access is needed, opens System Settings,
    /// then waits until the user turns it on and starts automatically.
    func requestAccessibility() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "MissionDeck needs Accessibility access"
        alert.informativeText = """
        To find the windows shown in Mission Control and close, minimize, hide or quit them, \
        MissionDeck needs Accessibility access.

        Click “Open System Settings”, then turn on MissionDeck under \
        Privacy & Security → Accessibility. MissionDeck starts working as soon as you do.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            AX.promptForTrust()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        waitForPermission()
    }

    fileprivate func waitForPermission() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard AX.isTrusted else { return }
            timer.invalidate()
            self?.permissionTimer = nil
            self?.startEngine()
        }
    }

    private func startEngine() {
        if engine.start() { return }

        // Right after permission is granted, creating the event tap can fail for a moment.
        startAttempts += 1
        if startAttempts < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startEngine()
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "MissionDeck couldn’t start"
            alert.informativeText = "Accessibility access looks enabled, but macOS refused the keyboard/mouse hook. Quit MissionDeck and open it again."
            alert.runModal()
        }
    }
}
