import Darwin
import Foundation
import NotchBotCore
import NotchBotIntegrationCore
import ServiceManagement

@MainActor
final class IntegrationInstaller: ObservableObject {
    struct Environment {
        var fileManager: FileManager
        var homeDirectory: URL
        var applicationSupportDirectory: URL
        var defaults: UserDefaults
        var bundledHookExecutable: URL?
        var makeUUID: () -> UUID
        var fileWriter: any AtomicFileWriting

        static var live: Environment {
            let fileManager = FileManager.default
            let packagedHelper = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers", isDirectory: true)
                .appendingPathComponent("notchbot-hook")
            let developmentHelper = Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("notchbot-hook")
            let bundledHelper = Bundle.main.url(forAuxiliaryExecutable: "notchbot-hook")
                ?? (fileManager.isExecutableFile(atPath: packagedHelper.path) ? packagedHelper : nil)
                ?? developmentHelper.flatMap {
                    fileManager.isExecutableFile(atPath: $0.path) ? $0 : nil
                }
            return Environment(
                fileManager: fileManager,
                homeDirectory: fileManager.homeDirectoryForCurrentUser,
                applicationSupportDirectory: NotchBotPaths.applicationSupportDirectory,
                defaults: .standard,
                bundledHookExecutable: bundledHelper,
                makeUUID: UUID.init,
                fileWriter: SecureAtomicFileWriter()
            )
        }
    }

    @Published private(set) var message = "Integrations not installed"
    @Published private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var requiresUpdate = false
    @Published private(set) var costTrackingEnabled: Bool

    private static let costTrackingKey = "costTrackingEnabled"

    private let environment: Environment
    private var fileManager: FileManager { environment.fileManager }

    init(environment: Environment = .live) {
        self.environment = environment
        costTrackingEnabled = environment.defaults.bool(forKey: Self.costTrackingKey)
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
            let helperExists = itemExists(at: installedHookURL)
            let helperIsOwned = helperExists ? try isOwnedHelper() : false
            if helperExists && !helperIsOwned && !pluginIsLegacy && !claudeIsLegacy {
                throw IntegrationError.unrelatedManagedFile(installedHookURL.path)
            }
            if itemExists(at: helperOwnershipURL), !(try isOwnedHelperMarker()) {
                throw IntegrationError.unrelatedManagedFile(helperOwnershipURL.path)
            }
            if itemExists(at: installStatusURL), !(try isOwnedInstallStatus()) {
                throw IntegrationError.unrelatedManagedFile(installStatusURL.path)
            }

            try updateClaudeSettings(install: false)
            if pluginExists { try fileManager.removeItem(at: openCodePluginURL) }
            if itemExists(at: installedHookURL) {
                try fileManager.removeItem(at: installedHookURL)
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
            guard itemExists(at: installedHookURL), itemExists(at: openCodePluginURL) else {
                message = "Install integrations first"
                return
            }
            try enableCostTrackingFiles()
            environment.defaults.set(true, forKey: Self.costTrackingKey)
            costTrackingEnabled = true
            message = "Cost tracking enabled"
        } catch {
            if (try? isOwnedPlugin(at: openCodePluginURL)) == true {
                try? writeOpenCodePlugin(
                    hookURL: installedHookURL,
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
        environment.applicationSupportDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("notchbot-statusline")
    }

    private var statusLineStateURL: URL {
        environment.applicationSupportDirectory.appendingPathComponent("statusline-state.json")
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
                hookPath: installedHookURL.path,
                existingCommand: originalCommand
            )
            try writeAtomically(Data(script.utf8), to: statusLineWrapperURL, permissions: 0o700)
            try writeOpenCodePlugin(hookURL: installedHookURL, includeCostTracking: true)
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
            hookPath: installedHookURL.path,
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
        try writeOpenCodePlugin(hookURL: installedHookURL, includeCostTracking: true)
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
            try writeOpenCodePlugin(hookURL: installedHookURL, includeCostTracking: false)
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
        environment.defaults.set(false, forKey: Self.costTrackingKey)
        DailyCostPreference.clear(from: environment.defaults)
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
            if itemExists(at: installedHookURL) || itemExists(at: openCodePluginURL) {
                message = "Integration update required"
                requiresUpdate = true
            }
            return
        }
        message = "Integration files installed"
        requiresUpdate = false
    }

    private func installHookExecutable(allowLegacyUpdate: Bool) throws -> URL {
        let destination = installedHookURL
        try preparePrivateSupportDirectory()
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try secureDirectory(destination.deletingLastPathComponent(), permissions: 0o700)
        if itemExists(at: destination) {
            guard (try isOwnedHelper()) || allowLegacyUpdate else {
                throw IntegrationError.unrelatedManagedFile(destination.path)
            }
        }
        if itemExists(at: helperOwnershipURL), !(try regularFile(at: helperOwnershipURL)) {
            throw IntegrationError.unrelatedManagedFile(helperOwnershipURL.path)
        }
        guard let source = environment.bundledHookExecutable else {
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

    private var installedHookURL: URL {
        environment.applicationSupportDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("notchbot-hook")
    }

    private var openCodePluginURL: URL {
        environment.homeDirectory
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
        environment.homeDirectory.appendingPathComponent(".claude/settings.json")
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
            ? ClaudeHooks.merging(into: originalSettings, hookPath: installedHookURL.path)
            : ClaudeHooks.removing(from: originalSettings, hookPath: installedHookURL.path)
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
            let currentSnapshot = itemExists(at: settingsURL)
                ? try boundedSnapshot(at: settingsURL, maximum: 4 * 1_024 * 1_024)
                : nil
            guard currentSnapshot?.data ?? Data() == originalData else {
                throw IntegrationError.concurrentSettingsChange
            }
            try writeAtomically(
                updatedData,
                to: settingsURL,
                permissions: originalMode,
                expectation: currentSnapshot.map { .identity($0.identity) } ?? .absent
            )
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
            applicationSupportDirectory: environment.applicationSupportDirectory
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try secureDirectory(directory, permissions: 0o700)
        let url = directory.appendingPathComponent("claude-settings-\(environment.makeUUID().uuidString).backup")
        try writeAtomically(data, to: url, permissions: 0o600)
        try pruneSettingsBackups(preserving: url)
        return url
    }

    private func removeOwnedBackups() throws {
        let directory = NotchBotIntegrationFiles.backupDirectoryURL(
            applicationSupportDirectory: environment.applicationSupportDirectory
        )
        guard try privateDirectory(at: directory) else { return }
        let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for entry in entries where isSettingsBackup(entry) {
            guard try regularFile(at: entry) else { continue }
            try fileManager.removeItem(at: entry)
        }
        if try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty {
            try fileManager.removeItem(at: directory)
        }
    }

    private func pruneSettingsBackups(preserving current: URL) throws {
        let directory = current.deletingLastPathComponent()
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        let backups = try entries.filter {
            guard isSettingsBackup($0) else { return false }
            return try regularFile(at: $0)
        }
        let newest = try backups.sorted {
            let left = try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let right = try $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            if left == right { return $0.lastPathComponent > $1.lastPathComponent }
            return left > right
        }
        let currentPath = current.standardizedFileURL.path
        let retainedPaths = Set(
            [currentPath] + newest.lazy
                .map { $0.standardizedFileURL.path }
                .filter { $0 != currentPath }
                .prefix(4)
        )
        for backup in backups where !retainedPaths.contains(backup.standardizedFileURL.path) {
            try fileManager.removeItem(at: backup)
        }
    }

    private func isSettingsBackup(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let prefix = "claude-settings-"
        let suffix = ".backup"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let token = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard let uuid = UUID(uuidString: token) else { return false }
        return uuid.uuidString == token
    }

    private var legacyPrivacyPolicyURL: URL {
        environment.applicationSupportDirectory.appendingPathComponent("integration-privacy.json")
    }

    private var installStatusURL: URL {
        NotchBotIntegrationFiles.installStatusURL(
            applicationSupportDirectory: environment.applicationSupportDirectory
        )
    }

    private var helperOwnershipURL: URL {
        NotchBotIntegrationFiles.helperOwnershipURL(helperURL: installedHookURL)
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
            hookPath: installedHookURL.path
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
        if itemExists(at: installedHookURL) {
            guard (try isOwnedHelper()) || allowHelperUpdate else {
                throw IntegrationError.unrelatedManagedFile(installedHookURL.path)
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
            itemExists(at: installedHookURL),
            try regularFile(at: installedHookURL),
            try isOwnedHelperMarker()
        else { return false }
        return true
    }

    private func isCurrentOwnedHelper() throws -> Bool {
        guard itemExists(at: installedHookURL), try regularFile(at: installedHookURL),
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

    private func writeAtomically(
        _ data: Data,
        to url: URL,
        permissions: Int,
        expectation: AtomicFileExpectation = .unconstrained
    ) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try environment.fileWriter.write(
            data,
            to: url,
            permissions: mode_t(permissions),
            expectation: expectation
        )
    }

    private func regularFile(at url: URL) throws -> Bool {
        let parentDescriptor = open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            if errno == ENOENT { return false }
            throw CocoaError(.fileReadUnknown)
        }
        defer { close(parentDescriptor) }
        var info = stat()
        guard fstatat(parentDescriptor, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
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
        let descriptor = try openRegularFile(at: url)
        guard descriptor >= 0 else {
            return nil
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid() else {
            throw IntegrationError.invalidManagedFile(url.path)
        }
        return Int(info.st_mode & mode_t(0o7777))
    }

    private func boundedData(at url: URL, maximum: Int) throws -> Data {
        try boundedSnapshot(at: url, maximum: maximum).data
    }

    private func boundedSnapshot(at url: URL, maximum: Int) throws -> ManagedFileSnapshot {
        let descriptor = try openRegularFile(at: url)
        guard descriptor >= 0 else { throw CocoaError(.fileNoSuchFile) }
        defer { close(descriptor) }
        var initialInfo = stat()
        guard fstat(descriptor, &initialInfo) == 0,
              (initialInfo.st_mode & S_IFMT) == S_IFREG,
              initialInfo.st_uid == getuid() else {
            throw IntegrationError.invalidManagedFile(url.path)
        }
        var data = Data(count: maximum + 1)
        let count = try data.withUnsafeMutableBytes { bytes -> Int in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw CocoaError(.fileReadUnknown)
                }
                if result == 0 { break }
                offset += result
            }
            return offset
        }
        data.count = count
        guard data.count <= maximum else { throw IntegrationError.managedFileTooLarge(url.path) }
        var finalInfo = stat()
        guard fstat(descriptor, &finalInfo) == 0,
              AtomicFileIdentity(initialInfo) == AtomicFileIdentity(finalInfo) else {
            throw IntegrationError.concurrentSettingsChange
        }
        return ManagedFileSnapshot(data: data, identity: AtomicFileIdentity(finalInfo))
    }

    private func openRegularFile(at url: URL) throws -> Int32 {
        let parent = url.deletingLastPathComponent()
        let directoryDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            if errno == ENOENT { return -1 }
            throw IntegrationError.invalidManagedFile(url.path)
        }
        defer { close(directoryDescriptor) }
        let descriptor = openat(directoryDescriptor, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return -1 }
            throw IntegrationError.invalidManagedFile(url.path)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid() else {
            close(descriptor)
            throw IntegrationError.invalidManagedFile(url.path)
        }
        return descriptor
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
        let directory = environment.applicationSupportDirectory
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
        try secureDirectory(directory, permissions: 0o700)
    }

    private func secureDirectory(_ directory: URL, permissions: Int) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw IntegrationError.unsafeSupportDirectory }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else {
            throw IntegrationError.unsafeSupportDirectory
        }
        guard fchmod(descriptor, mode_t(permissions)) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func privateDirectory(at directory: URL) throws -> Bool {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ELOOP || errno == ENOTDIR { return false }
            throw CocoaError(.fileReadUnknown)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        return (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }
}

private struct ManagedFileSnapshot {
    let data: Data
    let identity: AtomicFileIdentity
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
