import AppKit
import ApplicationServices

/// A real window that a Mission Control thumbnail stands for.
struct WindowTarget {
    let pid: pid_t
    let appName: String
    let window: AXUIElement
    let title: String
    let frame: CGRect         // real window frame (global, top-left origin)
    var size: CGSize { frame.size }   // used to find the visible picture inside a thumbnail
}

/// One window thumbnail as Mission Control draws it.
struct Thumbnail {
    let element: AXUIElement
    let title: String
    let groupTitle: String?      // app name, when "Group windows by application" is on
    let frame: CGRect            // global, top-left origin
    var target: WindowTarget?
    var center: CGPoint { frame.center }
}

struct MissionControlSnapshot {
    var isOpen: Bool
    var thumbnails: [Thumbnail]
    static let closed = MissionControlSnapshot(isOpen: false, thumbnails: [])
}

/// Mission Control is drawn by the Dock process. While it is open, the Dock exposes an
/// accessibility group with identifier "mc" containing one "mc.display" per screen, each with
/// a "mc.spaces" bar and a "mc.windows" area holding one element per window thumbnail.
/// This class polls that tree on a background queue and publishes snapshots on the main thread.
final class MissionControlMonitor {
    var onChange: ((MissionControlSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "MissionDeck.monitor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let matcher = WindowMatcher()

    private var dockElement: AXUIElement?
    private var isOpen = false
    private var last: [Thumbnail] = []
    private var lastFrameSignature = ""
    private var lastMatch = Date.distantPast
    private var forceRematch = false

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async {
            self.isOpen = false
            self.last = []
            self.lastFrameSignature = ""
        }
    }

    /// Call after acting on a window so the next tick re-matches thumbnails to windows.
    func invalidate() {
        queue.async { self.forceRematch = true }
    }

    // MARK: - Polling

    private func tick() {
        guard let root = missionControlRoot() else {
            if isOpen {
                isOpen = false
                last = []
                lastFrameSignature = ""
                publish(.closed)
            }
            return
        }

        var thumbs = collectThumbnails(in: root)
        let titlesChanged = thumbs.map(\.title) != last.map(\.title)
        let staleMatch = last.contains { $0.target == nil } && Date().timeIntervalSince(lastMatch) > 1.0
        let rematch = !isOpen || titlesChanged || forceRematch || staleMatch

        if rematch {
            matcher.resolve(&thumbs)
            lastMatch = Date()
            forceRematch = false
        } else {
            // Same thumbnails, maybe moved (opening animation, relayout): keep the matches.
            for i in thumbs.indices { thumbs[i].target = last[i].target }
        }

        let signature = frameSignature(thumbs)
        let changed = rematch || signature != lastFrameSignature
        isOpen = true
        last = thumbs
        lastFrameSignature = signature
        if changed {
            publish(MissionControlSnapshot(isOpen: true, thumbnails: thumbs))
        }
    }

    private func publish(_ snapshot: MissionControlSnapshot) {
        DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot) }
    }

    private func dock() -> AXUIElement? {
        if let d = dockElement { return d }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        dockElement = element
        return element
    }

    private func missionControlRoot() -> AXUIElement? {
        guard let dock = dock() else { return nil }
        guard let children = AX.children(dock) else {
            dockElement = nil   // Dock probably restarted; reconnect next tick
            return nil
        }
        return children.first { AX.identifier($0) == "mc" }
    }

    // MARK: - Reading thumbnails

    private func collectThumbnails(in root: AXUIElement) -> [Thumbnail] {
        var strict: [Thumbnail] = []   // found inside an "mc.windows" area
        var loose: [Thumbnail] = []    // fallback: any button outside the Spaces bar
        walk(root, depth: 0, group: nil, inWindowsArea: false, strict: &strict, loose: &loose)
        return strict.isEmpty ? loose : strict
    }

    private func walk(_ element: AXUIElement, depth: Int, group: String?, inWindowsArea: Bool,
                      strict: inout [Thumbnail], loose: inout [Thumbnail]) {
        guard depth <= 10 else { return }
        let ident = AX.identifier(element)
        if ident.hasPrefix("mc.spaces") { return }   // skip the Spaces bar at the top

        let role = AX.role(element)
        let windowsArea = inWindowsArea || ident.hasPrefix("mc.windows")
        let isContainer = role == kAXGroupRole || role == kAXListRole || role == "AXScrollArea"

        if !isContainer, depth > 0, let frame = AX.frame(element), frame.width >= 40, frame.height >= 30 {
            let label = AX.label(element)
            let thumb = Thumbnail(element: element, title: label, groupTitle: group, frame: frame, target: nil)
            if windowsArea, !label.isEmpty || role == kAXButtonRole {
                strict.append(thumb)
                return
            }
            if role == kAXButtonRole {
                loose.append(thumb)
                return
            }
        }

        var nextGroup = group
        if role == kAXGroupRole, windowsArea, !ident.hasPrefix("mc") {
            let label = AX.label(element)
            if !label.isEmpty { nextGroup = label }
        }
        for child in AX.children(element) ?? [] {
            walk(child, depth: depth + 1, group: nextGroup, inWindowsArea: windowsArea, strict: &strict, loose: &loose)
        }
    }

    private func frameSignature(_ thumbs: [Thumbnail]) -> String {
        thumbs.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height))" }
            .joined(separator: ";")
    }

    // MARK: - Debugging

    /// Dumps the Dock's accessibility tree plus the current thumbnail→window matches.
    /// Run it while Mission Control is open if the close button doesn't appear.
    /// Window titles can be private (email subjects, document names), so the report never
    /// contains them: only their length, and whether a thumbnail's title matches its window.
    func dumpTree(_ completion: @escaping (String) -> Void) {
        queue.async {
            var out = "MissionDeck accessibility dump — \(Date())\n"
            out += "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
            if let dock = self.dock() {
                self.dump(dock, depth: 0, into: &out)
            } else {
                out += "Dock process not found.\n"
            }
            out += "\n--- Window thumbnails found: \(self.last.count) ---\n"
            for t in self.last {
                let match = t.target.map { "\($0.appName) (title \($0.title == t.title ? "matches" : "differs"))" } ?? "UNMATCHED"
                out += "• title=\(Self.redact(t.title)) group=\(t.groupTitle ?? "-") frame=\(t.frame) → \(match)\n"
            }
            out += "\n--- Recent window actions ---\n" + WindowActions.recentLog()
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// "‹23 chars›" instead of the text itself.
    private static func redact(_ text: String) -> String {
        text.isEmpty ? "‹empty›" : "‹\(text.count) chars›"
    }

    private func dump(_ element: AXUIElement, depth: Int, into out: inout String) {
        guard depth <= 12 else { return }
        let pad = String(repeating: "  ", count: depth)
        let frame = AX.frame(element).map { " [\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))]" } ?? ""
        out += "\(pad)\(AX.role(element))"
        out += " sub=\(AX.string(element, kAXSubroleAttribute) ?? "-")"
        out += " id=\(AX.identifier(element))"
        out += " title=\(Self.redact(AX.string(element, kAXTitleAttribute) ?? ""))"
        out += " desc=\(Self.redact(AX.string(element, kAXDescriptionAttribute) ?? ""))\(frame)\n"
        for child in AX.children(element) ?? [] {
            dump(child, depth: depth + 1, into: &out)
        }
    }
}
