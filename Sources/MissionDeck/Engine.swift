import AppKit

private enum ArrowDirection { case left, right, up, down }

/// Ties everything together. All state lives on the main thread:
/// the event tap and the monitor's snapshots are both delivered there.
final class Engine {
    /// Marks events we post ourselves (cursor moves, clicks, keys) so we don't intercept them.
    static let syntheticTag: Int64 = 0x4D44_454B

    /// Closing and reopening Mission Control so it redraws without the closed window.
    private enum RefreshPhase { case idle, waitingForClose, waitingForReopen }

    /// Called if Accessibility permission is taken away while running.
    var onPermissionLost: (() -> Void)?

    private let monitor = MissionControlMonitor()
    private let tap = EventTapController()
    private let overlays = Overlays()
    private let settings = Settings.shared

    private var snapshot = MissionControlSnapshot.closed
    private var mouse = CGPoint.zero
    private var hoveredIndex: Int?
    private var selectedIndex: Int?      // set by arrow-key navigation
    private var swallowNextMouseUp = false
    private var actionInProgress = false
    private var refreshPhase = RefreshPhase.idle
    private var refreshAttempts = 0
    private var trustTimer: Timer?
    private(set) var isRunning = false

    private var buttonSize: CGFloat { CGFloat(settings.buttonSize.rawValue) }

    // MARK: - Lifecycle

    func start() -> Bool {
        if isRunning { return true }
        guard AX.isTrusted else { return false }
        tap.handler = { [weak self] type, event in
            self?.handle(type, event) ?? false
        }
        guard tap.start() else { return false }
        monitor.onChange = { [weak self] snapshot in
            self?.apply(snapshot)
        }
        monitor.start()
        isRunning = true

        // If the permission is removed (System Settings, tccutil…), remove the hook at once.
        // An active hook without permission is what freezes the keyboard and mouse.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, !AX.isTrusted else { return }
            self.stop()
            self.onPermissionLost?()
        }
        return true
    }

    /// Removes the keyboard/mouse hook and stops watching Mission Control.
    func stop() {
        trustTimer?.invalidate()
        trustTimer = nil
        tap.shutdown()
        monitor.stop()
        overlays.hideAll()
        snapshot = .closed
        hoveredIndex = nil
        selectedIndex = nil
        swallowNextMouseUp = false
        actionInProgress = false
        refreshPhase = .idle
        isRunning = false
    }

    func settingsChanged() {
        refreshOverlays()
    }

    func dumpTree(_ completion: @escaping (String) -> Void) {
        monitor.dumpTree(completion)
    }

    // MARK: - Snapshots

    private func apply(_ new: MissionControlSnapshot) {
        guard isRunning else { return }
        advanceRefresh(missionControlIsOpen: new.isOpen)

        let wasOpen = snapshot.isOpen
        let previousSelection = selectedIndex.flatMap { snapshot.thumbnails[safe: $0] }
        let titlesChanged = new.thumbnails.map(\.title) != snapshot.thumbnails.map(\.title)
        snapshot = new

        // The hook is only active while Mission Control is on screen.
        tap.setEnabled(new.isOpen)

        guard new.isOpen else {
            hoveredIndex = nil
            selectedIndex = nil
            swallowNextMouseUp = false
            overlays.hideAll()
            return
        }

        if !wasOpen {
            if let location = CGEvent(source: nil)?.location { mouse = location }
            selectedIndex = nil
            hoveredIndex = nil
        } else {
            if titlesChanged { hoveredIndex = nil }
            if let previous = previousSelection {
                selectedIndex = indexOfThumbnail(titled: previous.title, nearest: previous.center)
            }
        }
        refreshOverlays()
    }

    private func refreshOverlays() {
        guard isRunning, snapshot.isOpen, refreshPhase == .idle, !actionInProgress else {
            overlays.hideAll()
            return
        }
        hoveredIndex = hitTest(mouse)
        let thumbs = snapshot.thumbnails

        if settings.isOn(.arrowKeys), let i = selectedIndex, let thumb = thumbs[safe: i] {
            overlays.showRing(around: visibleRect(of: thumb))
        } else {
            overlays.hideRing()
        }

        if settings.isOn(.closeButton),
           let i = hoveredIndex ?? selectedIndex,
           let thumb = thumbs[safe: i], thumb.target != nil {
            overlays.showCloseButton(for: visibleRect(of: thumb), size: buttonSize)
        } else {
            overlays.hideCloseButton()
        }
    }

    /// The window picture inside a thumbnail. Mission Control keeps each window's shape,
    /// so we fit the real window's proportions into the thumbnail to find its true edges.
    private func visibleRect(of thumb: Thumbnail) -> CGRect {
        let box = thumb.frame
        guard let size = thumb.target?.size, size.width > 0, size.height > 0,
              box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }

    private func closeHitRect(of thumb: Thumbnail) -> CGRect {
        Overlays.closeButtonHitRect(for: visibleRect(of: thumb), size: buttonSize)
    }

    private func hitTest(_ point: CGPoint) -> Int? {
        let thumbs = snapshot.thumbnails

        // Half of the ✕ sits outside the window; keep hovering while the pointer is on it.
        if let h = hoveredIndex, let thumb = thumbs[safe: h], thumb.target != nil,
           settings.isOn(.closeButton), closeHitRect(of: thumb).contains(point) {
            return h
        }

        var best: Int?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for (i, thumb) in thumbs.enumerated() where thumb.frame.contains(point) {
            let area = thumb.frame.width * thumb.frame.height
            if area < bestArea {
                bestArea = area
                best = i
            }
        }
        return best
    }

    private func indexOfThumbnail(titled title: String, nearest point: CGPoint) -> Int? {
        var best: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (i, thumb) in snapshot.thumbnails.enumerated() where thumb.title == title {
            let d = hypot(thumb.center.x - point.x, thumb.center.y - point.y)
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    // MARK: - Events

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard isRunning else { return false }
        let synthetic = event.getIntegerValueField(.eventSourceUserData) == Engine.syntheticTag

        // Finish swallowing a click on the ✕.
        if type == .leftMouseUp && swallowNextMouseUp && !synthetic {
            swallowNextMouseUp = false
            return true
        }

        guard snapshot.isOpen, refreshPhase == .idle else { return false }

        switch type {
        case .mouseMoved, .leftMouseDragged:
            mouse = event.location
            if !synthetic { selectedIndex = nil }   // real mouse movement ends keyboard mode
            refreshOverlays()
            return false

        case .leftMouseDown:
            guard !synthetic, !actionInProgress else { return false }
            mouse = event.location
            refreshOverlays()
            if settings.isOn(.closeButton),
               let i = hoveredIndex,
               let thumb = snapshot.thumbnails[safe: i], thumb.target != nil,
               closeHitRect(of: thumb).contains(mouse) {
                swallowNextMouseUp = true
                perform(.close, on: i)
                return true   // Mission Control never sees this click
            }
            return false

        case .keyDown:
            return synthetic ? false : handleKey(event)

        default:
            return false
        }
    }

    private func handleKey(_ event: CGEvent) -> Bool {
        let flags = event.flags
        let command = flags.contains(.maskCommand)
        let otherModifiers = flags.contains(.maskShift) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if command && !otherModifiers {
            // Read the typed letter (not the key position) so AZERTY etc. work too.
            let letter = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased() ?? ""
            let action: WindowAction?
            switch letter {
            case "w" where settings.isOn(.closeShortcut):    action = .close
            case "m" where settings.isOn(.minimizeShortcut): action = .minimize
            case "h" where settings.isOn(.hideShortcut):     action = .hide
            case "q" where settings.isOn(.quitShortcut):     action = .quit
            default:                                          action = nil
            }
            guard let action = action else { return false }
            if isRepeat || actionInProgress { return true }   // holding ⌘W must not close a string of windows

            guard let i = hoveredIndex ?? selectedIndex,
                  snapshot.thumbnails[safe: i]?.target != nil else { return false }
            perform(action, on: i)
            return true
        }

        if !command && !otherModifiers && settings.isOn(.arrowKeys) {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            switch code {
            case KeyCode.left:  return moveSelection(.left)
            case KeyCode.right: return moveSelection(.right)
            case KeyCode.up:    return moveSelection(.up)
            case KeyCode.down:  return moveSelection(.down)
            case KeyCode.returnKey, KeyCode.enter:
                guard let i = selectedIndex, let thumb = snapshot.thumbnails[safe: i] else { return false }
                click(at: thumb.center)   // same as clicking the thumbnail: opens that window
                return true
            default:
                break
            }
        }
        return false
    }

    // MARK: - Arrow-key navigation

    private func moveSelection(_ direction: ArrowDirection) -> Bool {
        let thumbs = snapshot.thumbnails
        guard !thumbs.isEmpty else { return false }

        guard let current = selectedIndex ?? hoveredIndex, let from = thumbs[safe: current] else {
            // Nothing selected yet: start at the top-left window.
            let first = thumbs.indices.min { a, b in
                (thumbs[a].frame.minY, thumbs[a].frame.minX) < (thumbs[b].frame.minY, thumbs[b].frame.minX)
            }!
            select(first)
            return true
        }

        var best: Int?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for (i, thumb) in thumbs.enumerated() where i != current {
            let dx = thumb.center.x - from.center.x
            let dy = thumb.center.y - from.center.y   // y grows downward
            let along: CGFloat
            let across: CGFloat
            switch direction {
            case .left:  along = -dx; across = abs(dy)
            case .right: along = dx;  across = abs(dy)
            case .up:    along = -dy; across = abs(dx)
            case .down:  along = dy;  across = abs(dx)
            }
            guard along > 1 else { continue }
            let score = along + across * 2
            if score < bestScore {
                bestScore = score
                best = i
            }
        }
        if let best = best { select(best) }
        return true
    }

    private func select(_ index: Int) {
        guard let thumb = snapshot.thumbnails[safe: index] else { return }
        selectedIndex = index
        mouse = thumb.center
        moveCursor(to: thumb.center)   // lets Mission Control show its own highlight too
        refreshOverlays()
    }

    // MARK: - Actions

    private func perform(_ action: WindowAction, on index: Int) {
        guard let thumb = snapshot.thumbnails[safe: index], let target = thumb.target else {
            NSSound.beep()
            return
        }
        let closedFrame = thumb.frame
        let closedTitle = thumb.title

        actionInProgress = true
        overlays.hideAll()
        selectedIndex = nil

        WindowActions.perform(action, on: target) { [weak self] succeeded in
            guard let self = self, self.isRunning else { return }
            self.actionInProgress = false
            self.monitor.invalidate()

            guard succeeded else {
                // The app refused (e.g. a "Save changes?" sheet). Keep the ✕ available.
                NSSound.beep()
                self.refreshOverlays()
                return
            }
            self.hoveredIndex = nil
            // Give Mission Control a moment to update on its own, then check for a ghost.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.removeGhostIfNeeded(at: closedFrame, title: closedTitle)
            }
            self.refreshOverlays()
        }
    }

    // MARK: - Ghost windows

    /// Mission Control sometimes keeps drawing a window after it's gone. If a thumbnail is
    /// still where the closed window was, close and reopen Mission Control so it redraws.
    private func removeGhostIfNeeded(at closedFrame: CGRect, title: String) {
        guard isRunning, settings.isOn(.refreshAfterAction), snapshot.isOpen, refreshPhase == .idle else { return }
        guard ghostStillVisible(at: closedFrame) else { return }
        ghostTitle = title
        refreshAttempts = 0
        startRefresh()
    }

    private var ghostTitle = ""

    private func ghostStillVisible(at frame: CGRect) -> Bool {
        snapshot.thumbnails.contains {
            abs($0.frame.minX - frame.minX) < 4 && abs($0.frame.minY - frame.minY) < 4 &&
            abs($0.frame.width - frame.width) < 4 && abs($0.frame.height - frame.height) < 4
        }
    }

    private func startRefresh() {
        refreshAttempts += 1
        refreshPhase = .waitingForClose
        overlays.hideAll()
        MissionControlToggle.toggle()
        scheduleRefreshSafetyNet()
    }

    /// Never leave the app stuck if Mission Control didn't respond.
    private func scheduleRefreshSafetyNet() {
        let attempt = refreshAttempts
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.refreshPhase != .idle, self.refreshAttempts == attempt else { return }
            self.refreshPhase = .idle
            self.refreshOverlays()
        }
    }

    private func advanceRefresh(missionControlIsOpen isOpen: Bool) {
        switch refreshPhase {
        case .waitingForClose where !isOpen:
            refreshPhase = .waitingForReopen
            // Let the Dock finish its closing animation before reopening.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                MissionControlToggle.toggle()
            }
        case .waitingForReopen where isOpen:
            refreshPhase = .idle
            // Check once more after the opening animation; retry a single time if still there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self, self.isRunning, self.snapshot.isOpen,
                      self.refreshPhase == .idle, self.refreshAttempts < 2 else { return }
                // A ghost has the closed window's title but no real window behind it.
                let stillThere = self.snapshot.thumbnails.contains { $0.target == nil && $0.title == self.ghostTitle }
                if stillThere { self.startRefresh() }
            }
        default:
            break
        }
    }

    // MARK: - Synthetic input

    private func moveCursor(to point: CGPoint) {
        post(.mouseMoved, at: point)
    }

    private func click(at point: CGPoint) {
        post(.leftMouseDown, at: point)
        post(.leftMouseUp, at: point)
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Engine.syntheticTag)
        event.post(tap: .cghidEventTap)
    }
}
