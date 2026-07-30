import Foundation

public enum DisplaySelection: Hashable, Sendable {
    case automatic
    case all
    case display(String)
}

public enum DisplaySelectionPreference {
    public static let defaultsKey = "selectedDisplay"

    public static func load(from defaults: UserDefaults) -> DisplaySelection {
        guard let storedValue = defaults.string(forKey: defaultsKey) else {
            return .automatic
        }

        switch storedValue {
        case "automatic":
            return .automatic
        case "all":
            return .all
        default:
            guard let identifier = UUID(uuidString: storedValue)?.uuidString else {
                return .automatic
            }
            return .display(identifier)
        }
    }

    public static func save(_ selection: DisplaySelection, to defaults: UserDefaults) {
        let storedValue = switch selection {
        case .automatic:
            "automatic"
        case .all:
            "all"
        case let .display(identifier):
            identifier
        }
        defaults.set(storedValue, forKey: defaultsKey)
    }
}
