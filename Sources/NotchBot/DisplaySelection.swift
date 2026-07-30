import AppKit
import Combine
import CoreGraphics
import NotchBotCore

struct DisplayOption: Identifiable, Equatable {
    let id: String
    let name: String
}

struct DisplayTarget {
    let id: String
    let selectionIdentifier: String?
    let screen: NSScreen
}

@MainActor
final class DisplaySelectionModel: ObservableObject {
    @Published var selection: DisplaySelection {
        didSet {
            DisplaySelectionPreference.save(selection, to: defaults)
        }
    }

    @Published private(set) var options: [DisplayOption] = []
    @Published private(set) var screenRevision = 0

    private let defaults: UserDefaults
    private var screenObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = DisplaySelectionPreference.load(from: defaults)
        DisplaySelectionPreference.save(selection, to: defaults)
        refreshScreens()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshScreens()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    var hasUnavailableSelection: Bool {
        guard case let .display(identifier) = selection else { return false }
        return !options.contains(where: { $0.id == identifier })
    }

    func resolvedTargets() -> [DisplayTarget] {
        let targets = NSScreen.screens.map { screen in
            DisplayTarget(
                id: screen.panelIdentifier,
                selectionIdentifier: screen.persistentDisplayIdentifier,
                screen: screen
            )
        }

        switch selection {
        case .all:
            return targets
        case let .display(identifier):
            if let selected = targets.first(where: { $0.selectionIdentifier == identifier }) {
                return [selected]
            }
            return automaticTarget(from: targets).map { [$0] } ?? []
        case .automatic:
            return automaticTarget(from: targets).map { [$0] } ?? []
        }
    }

    private func refreshScreens() {
        let screens = NSScreen.screens
        let nameCounts = Dictionary(grouping: screens, by: \NSScreen.localizedName).mapValues(\.count)
        var nameIndexes: [String: Int] = [:]

        options = screens.compactMap { screen in
            guard let identifier = screen.persistentDisplayIdentifier else { return nil }
            let name = screen.localizedName
            nameIndexes[name, default: 0] += 1
            let displayName = nameCounts[name, default: 0] > 1
                ? "\(name) \(nameIndexes[name, default: 1])"
                : name
            return DisplayOption(id: identifier, name: displayName)
        }
        screenRevision += 1
    }

    private func automaticTarget(from targets: [DisplayTarget]) -> DisplayTarget? {
        targets.first(where: { NotchGeometry.hasPhysicalNotch(screen: $0.screen) })
            ?? NSScreen.main.flatMap { main in
                targets.first(where: { $0.screen === main })
            }
            ?? targets.first
    }
}

private extension NSScreen {
    var persistentDisplayIdentifier: String? {
        guard
            let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let displayUUID = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(screenNumber.uint32Value))
        else {
            return nil
        }
        return CFUUIDCreateString(nil, displayUUID.takeRetainedValue()) as String
    }

    var panelIdentifier: String {
        persistentDisplayIdentifier ?? "screen-\(ObjectIdentifier(self).hashValue)"
    }
}
