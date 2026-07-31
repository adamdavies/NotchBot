import Darwin
import Foundation
import NotchBotCore
import NotchBotIntegrationCore
import ServiceManagement

@MainActor
final class IntegrationInstaller: ObservableObject {
    @Published private(set) var message = "Integrations not installed"
    @Published private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var requiresUpdate = false
    @Published private(set) var costTrackingEnabled: Bool

    private static let costTrackingKey = "costTrackingEnabled"

    private let fileManager = FileManager.default

    init() {
        costTrackingEnabled = UserDefaults.standard.bool(forKey: Self.costTrackingKey)
        refreshStatus()
    }

    func install() {
        performInstallation(allowLegacyUpdate: false)
    }

    /// This distinct user action is required to replace the less-private v0.1 generated files.
    func updateIntegrations() {
        performInstallation(allowLegacyUpdate: true)
    }

    func uninstall() {
        do {
            if costTrackingEnabled || itemExists(at: statusLineStateURL) {
                try disableCostTrackingFiles()
                clearCostTrackingPreferences()
            }
            let pluginExists = itemExists(at: openCodePluginURL)
            let pluginIsLegacy = pluginExists
                ? try isLegacyPlugin(at: openCodePluginURL) || isPreviousPlugin(at: openCodePluginURL)
                : false
            let claudeIsLegacy = try hasManagedClaudeHooks()
            let pluginIsOwned = pluginExists ? try isOwnedPlugin(at: openCodePluginURL) : false
            if pluginExists && !pluginIsOwned && !pluginIsLegacy {
                throw IntegrationError.unrelatedManagedFile(openCodePluginURL.path)
            }
            let helperExists = itemExists(at: NotchBotPaths.installedHookURL)
            let helperIsOwned = helperExists ? try isOwnedHelper() : false
            if helperExists && !helperIsOwned && !pluginIsLegacy && !claudeIsLegacy {
                throw IntegrationError.unrelatedManagedFile(NotchBotPaths.installedHookURL.path)
            }
            if itemExists(at: helperOwnershipURL), !(try isOwnedHelperMarker()) {
                throw IntegrationError.unrelatedManagedFile(helperOwnershipURL.path)
            }
            if itemExists(at: installStatusURL), !(try isOwnedInstallStatus()) {
                throw IntegrationError.unrelatedManagedFile(installStatusURL.path)
            }

            try updateClaudeSettings(install: false)
            if pluginExists { try fileManager.removeItem(at: openCodePluginURL) }
            if itemExists(at: NotchBotPaths.installedHookURL) {
                try fileManager.removeItem(at: NotchBotPaths.installedHookURL)
            }
            if itemExists(at: helperOwnershipURL) {
                try fileManager.removeItem(at: helperOwnershipURL)
            }
            try removeOwnedBackups()
            if itemExists(at: installStatusURL) {
                try fileManager.removeItem(at: installStatusURL)
            }
            try removeLegacyPrivacyPolicyIfOwned()
            message = "Integrations removed"
            costTrackingEnabled = false
            requiresUpdate = false
        } catch {
            message = "Removal failed: \(error.localizedDescription)"
        }
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            message = "Launch at login failed: \(error.localizedDescription)"
        }
    }

    func enableCostTracking() {
        do {
            guard itemExists(at: NotchBotPaths.installedHookURL), itemExists(at: openCodePluginURL) else {
                message = "Install integrations first"
                return
            }
            try enableCostTrackingFiles()
            UserDefaults.standard.set(true, forKey: Self.costTrackingKey)
            costTrackingEnabled = true
            message = "Cost tracking enabled"
        } catch {
            if (try? isOwnedPlugin(at: openCodePluginURL)) == true {
                try? writeOpenCodePlugin(
                    hookURL: NotchBotPaths.installedHookURL,
                    includeCostTracking: false
                )
            }
            cleanupIncompleteCostTrackingFiles()
            message = "Cost tracking failed: \(error.localizedDescription)"
        }
    }

    func disableCostTracking() {
        do {
            try disableCostTrackingFiles()
            clearCostTrackingPreferences()
            costTrackingEnabled = false
            message = "Cost tracking disabled"
        } catch {
            message = "Disable cost tracking failed: \(error.localizedDescription)"
        }
    }

    private var statusLineWrapperURL: URL {
        NotchBotPaths.applicationSupportDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("notchbot-statusline")
    }

    private var statusLineStateURL: URL {
        NotchBotPaths.applicationSupportDirectory.appendingPathComponent("statusline-state.json")
    }

    private func enableCostTrackingFiles() throws {
        try preparePrivateSupportDirectory()
        guard try isOwnedHelper(), try isOwnedPlugin(at: openCodePluginURL) else {
            throw IntegrationError.explicitUpdateRequired
        }

        let settingsURL = claudeSettingsURL
        try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if itemExists(at: settingsURL), !(try regularFile(at: settingsURL)) {
            throw IntegrationError.unsafeClaudeSettings
        }
        let originalData = itemExists(at: settingsURL)
            ? try boundedData(at: settingsURL, maximum: 4 * 1_024 * 1_024)
            : Data()
        let originalMode = try fileMode(at: settingsURL) ?? 0o600
        var settings = try decodeJSONObject(originalData)

        if isManagedStatusLine(settings["statusLine"]), itemExists(at: statusLineStateURL) {
            var state = try readStatusLineState()
            if itemExists(at: statusLineWrapperURL) {
                guard try regularFile(at: statusLineWrapperURL) else {
                    throw IntegrationError.unrelatedManagedFile(statusLineWrapperURL.path)
                }
                let wrapper = try boundedString(at: statusLineWrapperURL, maximum: 128 * 1_024)
                guard StatusLineWrapper.isOwned(wrapper) || StatusLineWrapper.isPreviousVersion(wrapper) else {
                    throw IntegrationError.unrelatedManagedFile(statusLineWrapperURL.path)
                }
            }
            var originalCommand = command(fromStatusLineJSON: state.originalStatusLineJSON)
            if originalCommand.map(referencesStatusLineWrapper) == true {
                state = StatusLineWrapperState(originalStatusLineJSON: nil)
                originalCommand = nil
                try writeAtomically(try JSONEncoder().encode(state), to: statusLineStateURL, permissions: 0o600)
            }
            let script = StatusLineWrapper.generate(
                hookPath: NotchBotPaths.installedHookURL.path,
                existingCommand: originalCommand
            )
            try writeAtomically(Data(script.utf8), to: statusLineWrapperURL, permissions: 0o700)
            try writeOpenCodePlugin(hookURL: NotchBotPaths.installedHookURL, includeCostTracking: true)
            return
        }

        let originalStatusLineJSON: Data?
        if isManagedStatusLine(settings["statusLine"]), !itemExists(at: statusLineWrapperURL) {
            throw IntegrationError.invalidManagedFile(statusLineWrapperURL.path)
        }
        if isManagedStatusLine(settings["statusLine"]), itemExists(at: statusLineWrapperURL) {
            let legacyWrapper = try boundedString(at: statusLineWrapperURL, maximum: 128 * 1_024)
            guard StatusLineWrapper.isOwned(legacyWrapper) || StatusLineWrapper.isPreviousVersion(legacyWrapper) else {
                throw IntegrationError.unrelatedManagedFile(statusLineWrapperURL.path)
            }
            if let command = StatusLineWrapper.extractChainedCommand(legacyWrapper),
               !referencesStatusLineWrapper(command) {
                originalStatusLineJSON = try JSONSerialization.data(
                    withJSONObject: ["type": "command", "command": stripShellQuoting(command)],
                    options: [.sortedKeys]
                )
            } else {
                originalStatusLineJSON = nil
            }
        } else if let statusLine = settings["statusLine"] {
            guard let object = statusLine as? [String: Any],
                  object["type"] as? String == "command",
                  let command = object["command"] as? String, !command.isEmpty else {
                throw IntegrationError.invalidManagedFile("Claude statusLine")
            }
            guard !referencesStatusLineWrapper(command) else {
                throw IntegrationError.invalidManagedFile("Claude statusLine")
            }
            originalStatusLineJSON = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } else {
            originalStatusLineJSON = nil
        }

        if itemExists(at: statusLineWrapperURL) {
            guard try regularFile(at: statusLineWrapperURL) else {
                throw IntegrationError.unrelatedManagedFile(statusLineWrapperURL.path)
            }
            let contents = try boundedString(at: statusLineWrapperURL, maximum: 128 * 1_024)
            guard StatusLineWrapper.isOwned(contents) || StatusLineWrapper.isPreviousVersion(contents) else {
                throw IntegrationError.unrelatedManagedFile(statusLineWrapperURL.path)
            }
        }
        if itemExists(at: statusLineStateURL) {
            let existingState = try readStatusLineState()
            guard existingState.originalStatusLineJSON == originalStatusLineJSON else {
                throw IntegrationError.concurrentSettingsChange
            }
        }

        let originalCommand = command(fromStatusLineJSON: originalStatusLineJSON)
        let script = StatusLineWrapper.generate(
            hookPath: NotchBotPaths.installedHookURL.path,
            existingCommand: originalCommand
        )
        let state = StatusLineWrapperState(originalStatusLineJSON: originalStatusLineJSON)
        try writeAtomically(try JSONEncoder().encode(state), to: statusLineStateURL, permissions: 0o600)
        try writeAtomically(Data(script.utf8), to: statusLineWrapperURL, permissions: 0o700)

        var replacementStatusLine = originalStatusLineJSON.flatMap { data in
            try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } ?? [:]
        replacementStatusLine["type"] = "command"
        replacementStatusLine["command"] = StatusLineWrapper.command(wrapperPath: statusLineWrapperURL.path)
        settings["statusLine"] = replacementStatusLine
        try writeOpenCodePlugin(hookURL: NotchBotPaths.installedHookURL, includeCostTracking: true)
        try replaceClaudeSettings(originalData: originalData, originalMode: originalMode, with: settings)
    }

    private func disableCostTrackingFiles() throws {
        let state = try? readStatusLineState()
        let wrapperIsOwned: Bool
        if itemExists(at: statusLineWrapperURL), try regularFile(at: statusLineWrapperURL) {
            let wrapper = try boundedString(at: statusLineWrapperURL, maximum: 128 * 1_024)
            wrapperIsOwned = StatusLineWrapper.isOwned(wrapper) || StatusLineWrapper.isPreviousVersion(wrapper)
        } else {
            wrapperIsOwned = false
        }
        let settingsURL = claudeSettingsURL
        if itemExists(at: settingsURL) {
            guard try regularFile(at: settingsURL) else { throw IntegrationError.unsafeClaudeSettings }
            let originalData = try boundedData(at: settingsURL, maximum: 4 * 1_024 * 1_024)
            let originalMode = try fileMode(at: settingsURL) ?? 0o600
            var settings = try decodeJSONObject(originalData)
            if isManagedStatusLine(settings["statusLine"]) {
                if let saved = state?.originalStatusLineJSON {
                    guard let object = try JSONSerialization.jsonObject(with: saved) as? [String: Any] else {
                        throw IntegrationError.invalidManagedFile(statusLineStateURL.path)
                    }
                    settings["statusLine"] = object
                } else {
                    settings.removeValue(forKey: "statusLine")
                }
                try replaceClaudeSettings(originalData: originalData, originalMode: originalMode, with: settings)
            }
        }

        if itemExists(at: openCodePluginURL) {
            guard try isOwnedPlugin(at: openCodePluginURL) else {
                throw IntegrationError.unrelatedManagedFile(openCodePluginURL.path)
            }
            try writeOpenCodePlugin(hookURL: NotchBotPaths.installedHookURL, includeCostTracking: false)
        }
        if wrapperIsOwned { try? fileManager.removeItem(at: statusLineWrapperURL) }
        if state != nil { try? fileManager.removeItem(at: statusLineStateURL) }
    }

    private var managedStatusLine: [String: Any] {
        ["type": "command", "command": StatusLineWrapper.command(wrapperPath: statusLineWrapperURL.path)]
    }

    private func isManagedStatusLine(_ value: Any?) -> Bool {
        guard let value = value as? [String: Any],
              value["type"] as? String == "command" else { return false }
        return value["command"] as? String == managedStatusLine["command"] as? String
    }

    private func readStatusLineState() throws -> StatusLineWrapperState {
        guard itemExists(at: statusLineStateURL), try regularFile(at: statusLineStateURL) else {
            throw IntegrationError.invalidManagedFile(statusLineStateURL.path)
        }
        let data = try boundedData(at: statusLineStateURL, maximum: 128 * 1_024)
        guard let state = try? JSONDecoder().decode(StatusLineWrapperState.self, from: data), state.isOwned else {
            throw IntegrationError.invalidManagedFile(statusLineStateURL.path)
        }
        return state
    }

    private func command(fromStatusLineJSON data: Data?) -> String? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["command"] as? String
    }

    private func referencesStatusLineWrapper(_ command: String) -> Bool {
        StatusLineWrapper.referencesWrapper(command, atPath: statusLineWrapperURL.path)
    }

    private func cleanupIncompleteCostTrackingFiles() {
        guard let data = try? boundedData(at: claudeSettingsURL, maximum: 4 * 1_024 * 1_024),
              let settings = try? decodeJSONObject(data),
              !isManagedStatusLine(settings["statusLine"]) else { return }
        if let wrapper = try? boundedString(at: statusLineWrapperURL, maximum: 128 * 1_024),
           StatusLineWrapper.isOwned(wrapper) || StatusLineWrapper.isPreviousVersion(wrapper) {
            try? fileManager.removeItem(at: statusLineWrapperURL)
        }
        if (try? readStatusLineState()) != nil {
            try? fileManager.removeItem(at: statusLineStateURL)
        }
    }

    private func clearCostTrackingPreferences() {
        UserDefaults.standard.set(false, forKey: Self.costTrackingKey)
        DailyCostPreference.clear(from: .standard)
        NotificationCenter.default.post(name: .notchBotCostTrackingDisabled, object: nil)
    }

    private func performInstallation(allowLegacyUpdate: Bool) {
        do {
            try preparePrivateSupportDirectory()
            let outdated = try hasOutdatedInstallation()
            if outdated && !allowLegacyUpdate { throw IntegrationError.explicitUpdateRequired }
            let helperUpdateAllowed = if allowLegacyUpdate && outdated {
                try canReplaceOutdatedHelper()
            } else {
                false
            }
            try validateManagedDestinations(
                allowLegacyUpdate: allowLegacyUpdate && outdated,
                allowHelperUpdate: helperUpdateAllowed
            )
            let hookURL = try installHookExecutable(allowLegacyUpdate: helperUpdateAllowed)
            try installOpenCodePlugin(
                hookURL: hookURL,
                allowLegacyUpdate: allowLegacyUpdate && outdated
            )
            try updateClaudeSettings(install: true)
            if costTrackingEnabled {
                try enableCostTrackingFiles()
            }
            try writeInstallStatus()
            try removeLegacyPrivacyPolicyIfOwned()
            message = "OpenCode and Claude Code connected"
            requiresUpdate = false
        } catch {
            message = "Installation failed: \(error.localizedDescription)"
        }
    }

    private func refreshStatus() {
        guard
            let data = try? boundedData(at: installStatusURL, maximum: 4_096),
            let status = try? JSONDecoder().decode(IntegrationInstallStatus.self, from: data),
            status.version == IntegrationInstallStatus.currentVersion,
            (try? isCurrentOwnedHelper()) == true,
            (try? isOwnedPlugin(at: openCodePluginURL)) == true
        else {
            if itemExists(at: NotchBotPaths.installedHookURL) || itemExists(at: openCodePluginURL) {
                message = "Integration update required"
                requiresUpdate = true
            }
            return
        }
        message = "Integration files installed"
        requiresUpdate = false
    }

    private func installHookExecutable(allowLegacyUpdate: Bool) throws -> URL {
        let destination = NotchBotPaths.installedHookURL
        try preparePrivateSupportDirectory()
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: destination.deletingLastPathComponent().path
        )
        if itemExists(at: destination) {
            guard (try isOwnedHelper()) || allowLegacyUpdate else {
                throw IntegrationError.unrelatedManagedFile(destination.path)
            }
        }
        if itemExists(at: helperOwnershipURL), !(try regularFile(at: helperOwnershipURL)) {
            throw IntegrationError.unrelatedManagedFile(helperOwnershipURL.path)
        }
        guard let source = bundledHookExecutable else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "notchbot-hook"])
        }

        try writeAtomically(Data(contentsOf: source), to: destination, permissions: 0o700)
        try writeAtomically(
            Data(NotchBotIntegrationFiles.helperOwnershipMarker.utf8),
            to: helperOwnershipURL,
            permissions: 0o600
        )
        return destination
    }

    private var bundledHookExecutable: URL? {
        if let helper = Bundle.main.url(forAuxiliaryExecutable: "notchbot-hook") { return helper }
        let packagedHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("notchbot-hook")
        if fileManager.isExecutableFile(atPath: packagedHelper.path) { return packagedHelper }
        guard let executable = Bundle.main.executableURL else { return nil }
        let developmentHelper = executable.deletingLastPathComponent().appendingPathComponent("notchbot-hook")
        return fileManager.isExecutableFile(atPath: developmentHelper.path) ? developmentHelper : nil
    }

    private var openCodePluginURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/plugins", isDirectory: true)
            .appendingPathComponent("notchbot.js")
    }

    private func installOpenCodePlugin(hookURL: URL, allowLegacyUpdate: Bool) throws {
        if itemExists(at: openCodePluginURL) {
            let replaceable = try isOwnedPlugin(at: openCodePluginURL)
                || (allowLegacyUpdate && (isLegacyPlugin(at: openCodePluginURL) || isPreviousPlugin(at: openCodePluginURL)))
            guard replaceable else {
                throw IntegrationError.unrelatedManagedFile(openCodePluginURL.path)
            }
        }
        try writeOpenCodePlugin(hookURL: hookURL, includeCostTracking: costTrackingEnabled)
    }

    private func writeOpenCodePlugin(hookURL: URL, includeCostTracking: Bool) throws {
        try fileManager.createDirectory(
            at: openCodePluginURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plugin = OpenCodePlugin.generate(
            hookPath: hookURL.path,
            includeCostTracking: includeCostTracking
        )
        try writeAtomically(Data(plugin.utf8), to: openCodePluginURL, permissions: 0o600)
    }

    private var claudeSettingsURL: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    private func updateClaudeSettings(install: Bool) throws {
        let settingsURL = claudeSettingsURL
        if !install && !itemExists(at: settingsURL) { return }
        try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if itemExists(at: settingsURL), !(try regularFile(at: settingsURL)) {
            throw IntegrationError.unsafeClaudeSettings
        }

        let originalData = itemExists(at: settingsURL)
            ? try boundedData(at: settingsURL, maximum: 4 * 1_024 * 1_024)
            : Data()
        let originalMode = try fileMode(at: settingsURL) ?? 0o600
        let originalSettings = try decodeJSONObject(originalData)
        let updatedSettings = install
            ? ClaudeHooks.merging(into: originalSettings, hookPath: NotchBotPaths.installedHookURL.path)
            : ClaudeHooks.removing(from: originalSettings, hookPath: NotchBotPaths.installedHookURL.path)
        try replaceClaudeSettings(originalData: originalData, originalMode: originalMode, with: updatedSettings)
    }

    private func replaceClaudeSettings(
        originalData: Data,
        originalMode: Int,
        with updatedSettings: [String: Any]
    ) throws {
        let settingsURL = claudeSettingsURL
        let updatedData = try JSONSerialization.data(
            withJSONObject: updatedSettings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )

        let backupURL = try createSettingsBackup(data: originalData)
        do {
            let currentData = itemExists(at: settingsURL)
                ? try boundedData(at: settingsURL, maximum: 4 * 1_024 * 1_024)
                : Data()
            guard currentData == originalData else { throw IntegrationError.concurrentSettingsChange }
            try writeAtomically(updatedData, to: settingsURL, permissions: originalMode)
            let verification = try decodeJSONObject(
                boundedData(at: settingsURL, maximum: 4 * 1_024 * 1_024)
            )
            let expected = try decodeJSONObject(updatedData)
            guard NSDictionary(dictionary: verification).isEqual(to: expected) else {
                throw IntegrationError.settingsVerificationFailed
            }
            try fileManager.removeItem(at: backupURL)
        } catch {
            // The restrictive backup remains in NotchBot Application Support for recovery.
            throw error
        }
    }

    private func createSettingsBackup(data: Data) throws -> URL {
        let directory = NotchBotIntegrationFiles.backupDirectoryURL(
            applicationSupportDirectory: NotchBotPaths.applicationSupportDirectory
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("claude-settings-\(UUID().uuidString).backup")
        try writeAtomically(data, to: url, permissions: 0o600)
        return url
    }

    private func removeOwnedBackups() throws {
        let directory = NotchBotIntegrationFiles.backupDirectoryURL(
            applicationSupportDirectory: NotchBotPaths.applicationSupportDirectory
        )
        guard itemExists(at: directory) else { return }
        let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for entry in entries where entry.lastPathComponent.hasPrefix("claude-settings-")
            && entry.pathExtension == "backup" {
            guard try regularFile(at: entry) else { continue }
            try fileManager.removeItem(at: entry)
        }
        if try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty {
            try fileManager.removeItem(at: directory)
        }
    }

    private var legacyPrivacyPolicyURL: URL {
        NotchBotPaths.applicationSupportDirectory.appendingPathComponent("integration-privacy.json")
    }

    private var installStatusURL: URL {
        NotchBotIntegrationFiles.installStatusURL(
            applicationSupportDirectory: NotchBotPaths.applicationSupportDirectory
        )
    }

    private var helperOwnershipURL: URL {
        NotchBotIntegrationFiles.helperOwnershipURL(helperURL: NotchBotPaths.installedHookURL)
    }

    private func removeLegacyPrivacyPolicyIfOwned() throws {
        guard itemExists(at: legacyPrivacyPolicyURL), try regularFile(at: legacyPrivacyPolicyURL) else {
            return
        }
        guard let data = try? boundedData(at: legacyPrivacyPolicyURL, maximum: 4_096) else { return }
        guard LegacyIntegrationPrivacyPolicy.recognizes(data) else { return }
        try fileManager.removeItem(at: legacyPrivacyPolicyURL)
    }

    private func writeInstallStatus() throws {
        let data = try JSONEncoder().encode(IntegrationInstallStatus())
        try writeAtomically(data, to: installStatusURL, permissions: 0o600)
    }

    private func hasOutdatedInstallation() throws -> Bool {
        if itemExists(at: openCodePluginURL),
           try isLegacyPlugin(at: openCodePluginURL) || isPreviousPlugin(at: openCodePluginURL) {
            return true
        }
        if itemExists(at: installStatusURL) {
            let data = try boundedData(at: installStatusURL, maximum: 4_096)
            if let version = try? JSONDecoder().decode(IntegrationInstallStatus.self, from: data).version,
               (2..<IntegrationInstallStatus.currentVersion).contains(version) { return true }
        }
        if itemExists(at: helperOwnershipURL), try isPreviousHelperMarker() { return true }
        return try hasManagedClaudeHooks() && !isCurrentInstallationMarked()
    }

    private func canReplaceOutdatedHelper() throws -> Bool {
        if itemExists(at: helperOwnershipURL), try isOwnedHelperMarker() {
            return true
        }
        guard itemExists(at: openCodePluginURL), try isLegacyPlugin(at: openCodePluginURL) else {
            return false
        }
        return try hasManagedClaudeHooks()
    }

    private func hasV020OrCurrentMarker() throws -> Bool {
        if itemExists(at: installStatusURL), try isOwnedInstallStatus() { return true }
        if itemExists(at: helperOwnershipURL), try isOwnedHelperMarker() { return true }
        if itemExists(at: openCodePluginURL) {
            return try isOwnedPlugin(at: openCodePluginURL) || isPreviousPlugin(at: openCodePluginURL)
        }
        return false
    }

    private func isCurrentInstallationMarked() -> Bool {
        guard
            let data = try? boundedData(at: installStatusURL, maximum: 4_096),
            (try? JSONDecoder().decode(IntegrationInstallStatus.self, from: data).version)
                == IntegrationInstallStatus.currentVersion
        else { return false }
        return true
    }

    private func hasManagedClaudeHooks() throws -> Bool {
        guard itemExists(at: claudeSettingsURL), try regularFile(at: claudeSettingsURL) else {
            return false
        }
        let data = try boundedData(at: claudeSettingsURL, maximum: 4 * 1_024 * 1_024)
        return ClaudeHooks.containsManagedHandlers(
            in: try decodeJSONObject(data),
            hookPath: NotchBotPaths.installedHookURL.path
        )
    }

    private func validateManagedDestinations(allowLegacyUpdate: Bool, allowHelperUpdate: Bool) throws {
        if itemExists(at: openCodePluginURL) {
            let owned = try isOwnedPlugin(at: openCodePluginURL)
            let legacy = allowLegacyUpdate
                ? try isLegacyPlugin(at: openCodePluginURL) || isPreviousPlugin(at: openCodePluginURL)
                : false
            guard owned || legacy else {
                throw IntegrationError.unrelatedManagedFile(openCodePluginURL.path)
            }
        }
        if itemExists(at: NotchBotPaths.installedHookURL) {
            guard (try isOwnedHelper()) || allowHelperUpdate else {
                throw IntegrationError.unrelatedManagedFile(NotchBotPaths.installedHookURL.path)
            }
        }
        if itemExists(at: helperOwnershipURL), !(try isOwnedHelperMarker()) {
            throw IntegrationError.unrelatedManagedFile(helperOwnershipURL.path)
        }
        if itemExists(at: installStatusURL), !(try isOwnedInstallStatus()) {
            throw IntegrationError.unrelatedManagedFile(installStatusURL.path)
        }
    }

    private func isOwnedPlugin(at url: URL) throws -> Bool {
        guard itemExists(at: url), try regularFile(at: url) else { return false }
        return OpenCodePlugin.isOwned(try boundedString(at: url, maximum: 128 * 1_024))
    }

    private func isLegacyPlugin(at url: URL) throws -> Bool {
        guard itemExists(at: url), try regularFile(at: url) else { return false }
        return OpenCodePlugin.isLegacyV01(try boundedString(at: url, maximum: 128 * 1_024))
    }

    private func isPreviousPlugin(at url: URL) throws -> Bool {
        guard itemExists(at: url), try regularFile(at: url) else { return false }
        return OpenCodePlugin.isPreviousVersion(try boundedString(at: url, maximum: 128 * 1_024))
    }

    private func isOwnedHelper() throws -> Bool {
        guard
            itemExists(at: NotchBotPaths.installedHookURL),
            try regularFile(at: NotchBotPaths.installedHookURL),
            try isOwnedHelperMarker()
        else { return false }
        return true
    }

    private func isCurrentOwnedHelper() throws -> Bool {
        guard itemExists(at: NotchBotPaths.installedHookURL), try regularFile(at: NotchBotPaths.installedHookURL),
              itemExists(at: helperOwnershipURL), try regularFile(at: helperOwnershipURL) else { return false }
        return try boundedString(at: helperOwnershipURL, maximum: 128)
            == NotchBotIntegrationFiles.helperOwnershipMarker
    }

    private func isOwnedHelperMarker() throws -> Bool {
        guard itemExists(at: helperOwnershipURL), try regularFile(at: helperOwnershipURL) else {
            return false
        }
        let marker = try boundedString(at: helperOwnershipURL, maximum: 128)
        return marker == NotchBotIntegrationFiles.helperOwnershipMarker
            || NotchBotIntegrationFiles.previousHelperOwnershipMarkers.contains(marker)
    }

    private func isPreviousHelperMarker() throws -> Bool {
        guard itemExists(at: helperOwnershipURL), try regularFile(at: helperOwnershipURL) else {
            return false
        }
        return NotchBotIntegrationFiles.previousHelperOwnershipMarkers.contains(
            try boundedString(at: helperOwnershipURL, maximum: 128)
        )
    }

    private func isOwnedInstallStatus() throws -> Bool {
        guard itemExists(at: installStatusURL), try regularFile(at: installStatusURL) else {
            return false
        }
        let data = try boundedData(at: installStatusURL, maximum: 4_096)
        guard let version = try? JSONDecoder().decode(IntegrationInstallStatus.self, from: data).version else {
            return false
        }
        return (2...IntegrationInstallStatus.currentVersion).contains(version)
    }

    private func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if itemExists(at: url), !(try regularFile(at: url)) {
            throw IntegrationError.unrelatedManagedFile(url.path)
        }
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func regularFile(at url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw CocoaError(.fileReadUnknown)
        }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid()
    }

    private func itemExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func fileMode(at url: URL) throws -> Int? {
        guard itemExists(at: url) else { return nil }
        return (try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    private func boundedData(at url: URL, maximum: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maximum + 1)
        guard data.count <= maximum else { throw IntegrationError.managedFileTooLarge(url.path) }
        return data
    }

    private func boundedString(at url: URL, maximum: Int) throws -> String {
        guard let value = String(data: try boundedData(at: url, maximum: maximum), encoding: .utf8) else {
            throw IntegrationError.invalidManagedFile(url.path)
        }
        return value
    }

    private func stripShellQuoting(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        }
        return trimmed
    }

    private func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    private func preparePrivateSupportDirectory() throws {
        let directory = NotchBotPaths.applicationSupportDirectory
        if itemExists(at: directory) {
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid() else {
                throw IntegrationError.unsafeSupportDirectory
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}

private enum IntegrationError: LocalizedError {
    case explicitUpdateRequired
    case unrelatedManagedFile(String)
    case unsafeClaudeSettings
    case concurrentSettingsChange
    case settingsVerificationFailed
    case managedFileTooLarge(String)
    case invalidManagedFile(String)
    case unsafeSupportDirectory

    var errorDescription: String? {
        switch self {
        case .explicitUpdateRequired:
            "Installed integrations require an explicit update."
        case let .unrelatedManagedFile(path):
            "Refusing to replace an unverified file at \(path)."
        case .unsafeClaudeSettings:
            "Claude settings must be a regular file, not a symlink."
        case .concurrentSettingsChange:
            "Claude settings changed during installation; no replacement was made."
        case .settingsVerificationFailed:
            "Claude settings could not be verified after replacement."
        case let .managedFileTooLarge(path):
            "Managed file is unexpectedly large: \(path)."
        case let .invalidManagedFile(path):
            "Managed file is invalid: \(path)."
        case .unsafeSupportDirectory:
            "NotchBot's Application Support directory is not a private user-owned directory."
        }
    }
}
