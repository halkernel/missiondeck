import AppKit

// MissionDeck is a menu bar–only app (LSUIElement), so there is no main window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
