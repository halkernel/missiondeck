import AppKit
import ServiceManagement

/// The menu bar icon: status, per-feature toggles, button size, launch at login,
/// troubleshooting, uninstall, quit.
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let engine: Engine
    private let requestAccess: () -> Void

    init(engine: Engine, requestAccess: @escaping () -> Void) {
        self.engine = engine
        self.requestAccess = requestAccess
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "MissionDeck") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "MD"
            }
        }
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    fileprivate func rebuildMenu() {
        menu.removeAllItems()

        if !AX.isTrusted {
            menu.addItem(item("Grant Accessibility Access…", #selector(grantAccess)))
        } else if engine.isRunning {
            menu.addItem(label("MissionDeck is active"))
        } else {
            menu.addItem(label("Starting…"))
        }

        menu.addItem(.separator())
        menu.addItem(label("In Mission Control"))
        for key in Settings.Key.allCases {
            let toggle = item(key.title, #selector(toggleSetting(_:)))
            toggle.representedObject = key.rawValue
            toggle.state = Settings.shared.isOn(key) ? .on : .off
            menu.addItem(toggle)
        }

        let sizeItem = NSMenuItem(title: "Close Button Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for size in Settings.ButtonSize.allCases {
            let choice = item(size.title, #selector(chooseButtonSize(_:)))
            choice.tag = size.rawValue
            choice.state = Settings.shared.buttonSize == size ? .on : .off
            sizeMenu.addItem(choice)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        if #available(macOS 13.0, *) {
            let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(item("Troubleshoot: Save Mission Control Info…", #selector(dumpTree)))
        menu.addItem(item("Uninstall MissionDeck…", #selector(uninstall)))

        menu.addItem(.separator())
        let quit = item("Quit MissionDeck", #selector(quitApp))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    private func label(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    // MARK: - Actions

    @objc private func grantAccess() {
        requestAccess()
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = Settings.Key(rawValue: raw) else { return }
        Settings.shared.set(key, !Settings.shared.isOn(key))
        engine.settingsChanged()
    }

    @objc private func chooseButtonSize(_ sender: NSMenuItem) {
        guard let size = Settings.ButtonSize(rawValue: sender.tag) else { return }
        Settings.shared.buttonSize = size
        engine.settingsChanged()
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("Couldn’t change Launch at Login",
                      "\(error.localizedDescription)\n\nMake sure MissionDeck is in your Applications folder.")
        }
    }

    @objc private func dumpTree() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Open Mission Control now"
        alert.informativeText = "After you click OK you have 5 seconds to open Mission Control (F3, Control-↑, or swipe up with three fingers). MissionDeck will save what it sees to a text file and show it in Finder. Window titles are left out, so the file is safe to share. Nothing is sent anywhere."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.engine.dumpTree { text in
                let folder = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/MissionDeck", isDirectory: true)
                let file = folder.appendingPathComponent("MissionControl-AXTree.txt")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try text.write(to: file, atomically: true, encoding: .utf8)
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                } catch {
                    NSSound.beep()
                }
            }
        }
    }

    @objc private func uninstall() {
        Uninstaller.run(engine: engine)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func showAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }
}
