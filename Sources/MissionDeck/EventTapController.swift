import AppKit
import CoreGraphics

/// A session-wide event tap, used ONLY while Mission Control is open.
///
/// Safety rules (an active tap is powerful, and macOS freezes all input if the app loses
/// its Accessibility permission while a tap is active):
///  • the tap is switched off whenever Mission Control is closed;
///  • it is never switched on without Accessibility permission;
///  • shutdown() removes it completely; the uninstaller calls this before touching permissions.
final class EventTapController {
    var handler: ((CGEventType, CGEvent) -> Bool)?

    fileprivate var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    fileprivate private(set) var wantsEnabled = false

    func start() -> Bool {
        if machPort != nil { return true }

        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false   // usually means Accessibility access isn't granted (yet)
        }

        // Taps start enabled; keep it off until Mission Control actually opens.
        CGEvent.tapEnable(tap: port, enable: false)
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        machPort = port
        runLoopSource = source
        wantsEnabled = false
        return true
    }

    /// Turn event delivery on (Mission Control open) or off (closed).
    func setEnabled(_ enabled: Bool) {
        wantsEnabled = enabled
        guard let port = machPort else { return }
        CGEvent.tapEnable(tap: port, enable: enabled && AX.isTrusted)
    }

    /// Remove the tap entirely.
    func shutdown() {
        wantsEnabled = false
        if let port = machPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        machPort = nil
        runLoopSource = nil
    }

    fileprivate func reenableIfWanted() {
        guard wantsEnabled, AX.isTrusted, let port = machPort else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }
}

private func eventTapCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        controller.reenableIfWanted()
        return Unmanaged.passUnretained(event)
    default:
        guard controller.wantsEnabled else { return Unmanaged.passUnretained(event) }
        if controller.handler?(type, event) == true {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
