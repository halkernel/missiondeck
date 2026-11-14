import Foundation

/// User preferences (every feature can be switched off from the menu bar icon).
final class Settings {
    static let shared = Settings()

    enum Key: String, CaseIterable {
        case closeButton, closeShortcut, minimizeShortcut, hideShortcut, quitShortcut, arrowKeys, refreshAfterAction

        var title: String {
            switch self {
            case .closeButton:        return "Close Button on Hovered Window"
            case .closeShortcut:      return "⌘W  Close Window"
            case .minimizeShortcut:   return "⌘M  Minimize Window"
            case .hideShortcut:       return "⌘H  Hide App"
            case .quitShortcut:       return "⌘Q  Quit App"
            case .arrowKeys:          return "Arrow Keys to Move Between Windows"
            case .refreshAfterAction: return "Remove Closed Windows Right Away"
            }
        }
    }

    enum ButtonSize: Int, CaseIterable {
        case small = 28, medium = 36, large = 44

        var title: String {
            switch self {
            case .small:  return "Small"
            case .medium: return "Medium"
            case .large:  return "Large"
            }
        }
    }

    private let defaults = UserDefaults.standard
    private var cache: [Key: Bool] = [:]

    private init() {
        for key in Key.allCases {
            cache[key] = defaults.object(forKey: "pref." + key.rawValue) as? Bool ?? true
        }
    }

    func isOn(_ key: Key) -> Bool { cache[key] ?? true }

    func set(_ key: Key, _ on: Bool) {
        cache[key] = on
        defaults.set(on, forKey: "pref." + key.rawValue)
    }

    var buttonSize: ButtonSize {
        get { ButtonSize(rawValue: defaults.integer(forKey: "pref.buttonSize")) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "pref.buttonSize") }
    }
}

/// Virtual key codes for keys whose position doesn't depend on keyboard layout.
enum KeyCode {
    static let returnKey: Int64 = 36
    static let enter: Int64 = 76
    static let left: Int64 = 123
    static let right: Int64 = 124
    static let down: Int64 = 125
    static let up: Int64 = 126
}
