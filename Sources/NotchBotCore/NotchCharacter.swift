import Foundation

public enum NotchCharacter: String, CaseIterable, Identifiable, Sendable {
    case retro
    case blob
    case orb

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .retro: "Retro Bot"
        case .blob: "Blob Bot"
        case .orb: "Orb Bot"
        }
    }
}

public enum NotchCharacterPreference {
    public static let defaultsKey = "selectedCharacter"

    public static func load(from defaults: UserDefaults) -> NotchCharacter {
        defaults.string(forKey: defaultsKey)
            .flatMap(NotchCharacter.init(rawValue:)) ?? .retro
    }

    public static func save(_ character: NotchCharacter, to defaults: UserDefaults) {
        defaults.set(character.rawValue, forKey: defaultsKey)
    }
}
