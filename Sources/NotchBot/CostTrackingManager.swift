import Foundation
import NotchBotIntegrationCore

/// Installs and removes the opt-in status-line wrapper that reports Claude Code cost. The user's
/// original `statusLine` configuration is preserved verbatim and restored when tracking is off.
struct CostTrackingManager {
    let store: ManagedFileStore
    let paths: IntegrationPaths
    let ownership: IntegrationOwnership
    let settings: ClaudeSettingsManager
    let plugin: OpenCodePluginManager

    func enable() throws {
        try store.preparePrivateSupportDirectory(paths.applicationSupportDirectory)
        guard try ownership.isOwnedHelper(), try ownership.isOwnedPlugin(at: paths.openCodePlugin) else {
            throw IntegrationError.explicitUpdateRequired
        }

        let settingsURL = paths.claudeSettings
        try store.fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if store.itemExists(at: settingsURL), !(try store.regularFile(at: settingsURL)) {
            throw IntegrationError.unsafeClaudeSettings
        }
        let originalData = store.itemExists(at: settingsURL)
            ? try store.boundedData(at: settingsURL, maximum: 4 * 1_024 * 1_024)
            : Data()
        let originalMode = try store.fileMode(at: settingsURL) ?? 0o600
        var claudeSettings = try store.decodeJSONObject(originalData)

        // Already wrapped: refresh the wrapper in place rather than re-capturing the original.
        if isManagedStatusLine(claudeSettings["statusLine"]), store.itemExists(at: paths.statusLineState) {
            var state = try readState()
            if store.itemExists(at: paths.statusLineWrapper) {
                guard try store.regularFile(at: paths.statusLineWrapper) else {
                    throw IntegrationError.unrelatedManagedFile(paths.statusLineWrapper.path)
                }
                let wrapper = try store.boundedString(at: paths.statusLineWrapper, maximum: 128 * 1_024)
                guard StatusLineWrapper.isOwned(wrapper) || StatusLineWrapper.isPreviousVersion(wrapper) else {
                    throw IntegrationError.unrelatedManagedFile(paths.statusLineWrapper.path)
                }
            }
            var originalCommand = command(fromStatusLineJSON: state.originalStatusLineJSON)
            if originalCommand.map(referencesWrapper) == true {
                state = StatusLineWrapperState(originalStatusLineJSON: nil)
                originalCommand = nil
                try store.writeAtomically(
                    try JSONEncoder().encode(state),
                    to: paths.statusLineState,
                    permissions: 0o600
                )
            }
            let script = StatusLineWrapper.generate(
                hookPath: paths.installedHook.path,
                existingCommand: originalCommand
            )
            try store.writeAtomically(Data(script.utf8), to: paths.statusLineWrapper, permissions: 0o700)
            try plugin.write(hookURL: paths.installedHook, includeCostTracking: true)
            return
        }

        let originalStatusLineJSON = try capturedStatusLine(from: claudeSettings)

        if store.itemExists(at: paths.statusLineWrapper) {
            guard try store.regularFile(at: paths.statusLineWrapper) else {
                throw IntegrationError.unrelatedManagedFile(paths.statusLineWrapper.path)
            }
            let contents = try store.boundedString(at: paths.statusLineWrapper, maximum: 128 * 1_024)
            guard StatusLineWrapper.isOwned(contents) || StatusLineWrapper.isPreviousVersion(contents) else {
                throw IntegrationError.unrelatedManagedFile(paths.statusLineWrapper.path)
            }
        }
        if store.itemExists(at: paths.statusLineState) {
            let existingState = try readState()
            guard existingState.originalStatusLineJSON == originalStatusLineJSON else {
                throw IntegrationError.concurrentSettingsChange
            }
        }

        let originalCommand = command(fromStatusLineJSON: originalStatusLineJSON)
        let script = StatusLineWrapper.generate(
            hookPath: paths.installedHook.path,
            existingCommand: originalCommand
        )
        let state = StatusLineWrapperState(originalStatusLineJSON: originalStatusLineJSON)
        try store.writeAtomically(
            try JSONEncoder().encode(state),
            to: paths.statusLineState,
            permissions: 0o600
        )
        try store.writeAtomically(Data(script.utf8), to: paths.statusLineWrapper, permissions: 0o700)

        var replacementStatusLine = originalStatusLineJSON.flatMap { data in
            try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } ?? [:]
        replacementStatusLine["type"] = "command"
        replacementStatusLine["command"] = StatusLineWrapper.command(wrapperPath: paths.statusLineWrapper.path)
        claudeSettings["statusLine"] = replacementStatusLine
        try plugin.write(hookURL: paths.installedHook, includeCostTracking: true)
        try settings.replace(
            originalData: originalData,
            originalMode: originalMode,
            with: claudeSettings
        )
    }

    func disable(updatePlugin: Bool = true) throws {
        if updatePlugin, store.itemExists(at: paths.openCodePlugin),
           !(try ownership.isOwnedPlugin(at: paths.openCodePlugin)) {
            throw IntegrationError.unrelatedManagedFile(paths.openCodePlugin.path)
        }
        let wrapperIsOwned: Bool
        if store.itemExists(at: paths.statusLineWrapper), try store.regularFile(at: paths.statusLineWrapper) {
            let wrapper = try store.boundedString(at: paths.statusLineWrapper, maximum: 128 * 1_024)
            wrapperIsOwned = StatusLineWrapper.isOwned(wrapper) || StatusLineWrapper.isPreviousVersion(wrapper)
        } else {
            wrapperIsOwned = false
        }
        let settingsURL = paths.claudeSettings
        var state: StatusLineWrapperState?
        if store.itemExists(at: settingsURL) {
            guard try store.regularFile(at: settingsURL) else { throw IntegrationError.unsafeClaudeSettings }
            let originalData = try store.boundedData(at: settingsURL, maximum: 4 * 1_024 * 1_024)
            let originalMode = try store.fileMode(at: settingsURL) ?? 0o600
            var claudeSettings = try store.decodeJSONObject(originalData)
            if isManagedStatusLine(claudeSettings["statusLine"]) {
                state = try readState()
                if let saved = state?.originalStatusLineJSON {
                    guard let object = try JSONSerialization.jsonObject(with: saved) as? [String: Any] else {
                        throw IntegrationError.invalidManagedFile(paths.statusLineState.path)
                    }
                    claudeSettings["statusLine"] = object
                } else {
                    claudeSettings.removeValue(forKey: "statusLine")
                }
                try settings.replace(
                    originalData: originalData,
                    originalMode: originalMode,
                    with: claudeSettings
                )
            }
        }
        if state == nil {
            state = try? readState()
        }

        if updatePlugin, store.itemExists(at: paths.openCodePlugin) {
            try plugin.write(hookURL: paths.installedHook, includeCostTracking: false)
        }
        if wrapperIsOwned { try? store.fileManager.removeItem(at: paths.statusLineWrapper) }
        if state != nil { try? store.fileManager.removeItem(at: paths.statusLineState) }
    }

    /// Removes a half-written wrapper left behind when enabling failed before settings changed.
    func cleanupIncompleteFiles() {
        guard let data = try? store.boundedData(at: paths.claudeSettings, maximum: 4 * 1_024 * 1_024),
              let claudeSettings = try? store.decodeJSONObject(data),
              !isManagedStatusLine(claudeSettings["statusLine"]) else { return }
        if let wrapper = try? store.boundedString(at: paths.statusLineWrapper, maximum: 128 * 1_024),
           StatusLineWrapper.isOwned(wrapper) || StatusLineWrapper.isPreviousVersion(wrapper) {
            try? store.fileManager.removeItem(at: paths.statusLineWrapper)
        }
        if (try? readState()) != nil {
            try? store.fileManager.removeItem(at: paths.statusLineState)
        }
    }

    var managedStatusLineCommand: String {
        StatusLineWrapper.command(wrapperPath: paths.statusLineWrapper.path)
    }

    func isManagedStatusLine(_ value: Any?) -> Bool {
        guard let value = value as? [String: Any],
              value["type"] as? String == "command" else { return false }
        return value["command"] as? String == managedStatusLineCommand
    }

    private func capturedStatusLine(from claudeSettings: [String: Any]) throws -> Data? {
        if isManagedStatusLine(claudeSettings["statusLine"]), !store.itemExists(at: paths.statusLineWrapper) {
            throw IntegrationError.invalidManagedFile(paths.statusLineWrapper.path)
        }
        if isManagedStatusLine(claudeSettings["statusLine"]), store.itemExists(at: paths.statusLineWrapper) {
            let legacyWrapper = try store.boundedString(at: paths.statusLineWrapper, maximum: 128 * 1_024)
            guard StatusLineWrapper.isOwned(legacyWrapper)
                || StatusLineWrapper.isPreviousVersion(legacyWrapper) else {
                throw IntegrationError.unrelatedManagedFile(paths.statusLineWrapper.path)
            }
            if let command = StatusLineWrapper.extractChainedCommand(legacyWrapper),
               !referencesWrapper(command) {
                return try JSONSerialization.data(
                    withJSONObject: ["type": "command", "command": Self.stripShellQuoting(command)],
                    options: [.sortedKeys]
                )
            }
            return nil
        }
        if let statusLine = claudeSettings["statusLine"] {
            guard let object = statusLine as? [String: Any],
                  object["type"] as? String == "command",
                  let command = object["command"] as? String, !command.isEmpty else {
                throw IntegrationError.invalidManagedFile("Claude statusLine")
            }
            guard !referencesWrapper(command) else {
                throw IntegrationError.invalidManagedFile("Claude statusLine")
            }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        return nil
    }

    private func readState() throws -> StatusLineWrapperState {
        guard store.itemExists(at: paths.statusLineState),
              try store.regularFile(at: paths.statusLineState) else {
            throw IntegrationError.invalidManagedFile(paths.statusLineState.path)
        }
        let data = try store.boundedData(at: paths.statusLineState, maximum: 128 * 1_024)
        guard let state = try? JSONDecoder().decode(StatusLineWrapperState.self, from: data),
              state.isOwned else {
            throw IntegrationError.invalidManagedFile(paths.statusLineState.path)
        }
        return state
    }

    private func command(fromStatusLineJSON data: Data?) -> String? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["command"] as? String
    }

    private func referencesWrapper(_ command: String) -> Bool {
        StatusLineWrapper.referencesWrapper(command, atPath: paths.statusLineWrapper.path)
    }

    private static func stripShellQuoting(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        }
        return trimmed
    }
}
