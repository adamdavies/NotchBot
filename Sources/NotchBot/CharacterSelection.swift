import Combine
import Foundation
import NotchBotCore

@MainActor
final class AppearanceModel: ObservableObject {
    @Published var character: NotchCharacter {
        didSet {
            NotchCharacterPreference.save(character, to: defaults)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        character = NotchCharacterPreference.load(from: defaults)
        NotchCharacterPreference.save(character, to: defaults)
    }
}
