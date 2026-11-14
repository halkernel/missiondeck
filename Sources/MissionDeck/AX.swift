import AppKit
import ApplicationServices

/// Small, safe wrappers around the C Accessibility API.
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        value(element, attribute) as? Bool
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        value(element, attribute) as? [AXUIElement]
    }

    /// nil means the call failed (e.g. the process went away); [] means no children.
    static func children(_ element: AXUIElement) -> [AXUIElement]? {
        elements(element, kAXChildrenAttribute)
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(element, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func role(_ element: AXUIElement) -> String {
        string(element, kAXRoleAttribute) ?? ""
    }

    static func identifier(_ element: AXUIElement) -> String {
        string(element, "AXIdentifier") ?? ""
    }

    /// Title, falling back to description (Mission Control uses either, depending on macOS version).
    static func label(_ element: AXUIElement) -> String {
        if let t = string(element, kAXTitleAttribute), !t.isEmpty { return t }
        return string(element, kAXDescriptionAttribute) ?? ""
    }

    /// Frame in global screen coordinates (origin at top-left of the primary display, y grows downward).
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = axValue(element, kAXPositionAttribute, .cgPoint, CGPoint.zero),
              let size = axValue(element, kAXSizeAttribute, .cgSize, CGSize.zero) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func axValue<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType, _ initial: T) -> T? {
        guard let v = value(element, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var result = initial
        guard AXValueGetValue(v as! AXValue, type, &result) else { return nil }
        return result
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
