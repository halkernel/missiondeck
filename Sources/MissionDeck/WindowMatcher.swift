import AppKit
import ApplicationServices

/// Mission Control's thumbnails don't say which process owns them, so we match each thumbnail
/// to a real window (found through each app's accessibility tree) using its title, the app
/// group it sits in, and its shape (Mission Control keeps each window's aspect ratio).
/// Only confident matches are kept, so we never act on a window we're unsure about.
final class WindowMatcher {
    private struct Candidate {
        let target: WindowTarget
        let frame: CGRect
        let title: String
        let app: String
    }

    private let minimumScore = 35.0

    func resolve(_ thumbs: inout [Thumbnail]) {
        let candidates = loadCandidates()
        let server = WindowServer.allWindows()
        // Only trust the window server's on-screen flag if it reports some window as on screen.
        let serverIsUseful = candidates.contains {
            WindowServer.match(pid: $0.target.pid, frame: $0.frame, in: server)?.isOnScreen == true
        }
        var pairs: [(score: Double, thumb: Int, cand: Int)] = []

        for (ti, thumb) in thumbs.enumerated() {
            let title = normalize(thumb.title)
            let group = thumb.groupTitle.map(normalize)

            for (ci, cand) in candidates.enumerated() {
                var score = 0.0
                if !title.isEmpty && title == cand.title {
                    score += 100
                } else if title.count >= 3, cand.title.count >= 3,
                          cand.title.contains(title) || title.contains(cand.title) {
                    score += 45
                } else if !title.isEmpty && cand.title.isEmpty && title == cand.app {
                    score += 60
                } else if title.isEmpty && cand.title.isEmpty {
                    score += 15
                }

                if let group = group, !group.isEmpty {
                    score += (group == cand.app) ? 60 : -40
                }

                score -= aspectPenalty(thumb.frame, cand.frame)

                // A window the app has hidden (e.g. Spotify after closing) must not be matched
                // to the leftover "ghost" picture in Mission Control.
                if serverIsUseful,
                   WindowServer.match(pid: cand.target.pid, frame: cand.frame, in: server)?.isOnScreen == false {
                    score -= 200
                }
                if score >= minimumScore {
                    pairs.append((score, ti, ci))
                }
            }
        }

        // Greedy best-first assignment: each thumbnail and each window used once.
        pairs.sort { $0.score > $1.score }
        var usedThumbs = Set<Int>()
        var usedCands = Set<Int>()
        for pair in pairs where !usedThumbs.contains(pair.thumb) && !usedCands.contains(pair.cand) {
            thumbs[pair.thumb].target = candidates[pair.cand].target
            usedThumbs.insert(pair.thumb)
            usedCands.insert(pair.cand)
        }
    }

    private func loadCandidates() -> [Candidate] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        var result: [Candidate] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != myPID,
                  !app.isTerminated, !app.isHidden,
                  app.activationPolicy != .prohibited,
                  app.bundleIdentifier != "com.apple.dock" else { continue }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.25)   // don't let a hung app stall us
            guard let windows = AX.elements(axApp, kAXWindowsAttribute) else { continue }

            let appName = app.localizedName ?? ""
            for window in windows {
                guard AX.role(window) == kAXWindowRole,
                      AX.bool(window, kAXMinimizedAttribute) != true,
                      let frame = AX.frame(window), frame.width > 20, frame.height > 20 else { continue }
                let title = AX.string(window, kAXTitleAttribute) ?? ""
                let target = WindowTarget(pid: app.processIdentifier, appName: appName, window: window, title: title, frame: frame)
                result.append(Candidate(target: target, frame: frame, title: normalize(title), app: normalize(appName)))
            }
        }
        return result
    }

    private func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func aspectPenalty(_ a: CGRect, _ b: CGRect) -> Double {
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return 0 }
        let ratio = Double((a.width / a.height) / (b.width / b.height))
        return abs(log(ratio)) * 120
    }
}
