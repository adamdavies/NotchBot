import Foundation
import NotchBotIntegrationCore

/// Decides which on-disk files NotchBot may replace or remove, and which installed revision is
/// present. Ownership is proved by generated markers, never by path alone.
struct IntegrationOwnership {
    let store: ManagedFileStore
    let paths: IntegrationPaths

    func isOwnedPlugin(at url: URL) throws -> Bool {
        guard store.itemExists(at: url), try store.regularFile(at: url) else { return false }
        return OpenCodePlugin.isOwned(try store.boundedString(at: url, maximum: 128 * 1_024))
    }

    func isLegacyPlugin(at url: URL) throws -> Bool {
        guard store.itemExists(at: url), try store.regularFile(at: url) else { return false }
        return OpenCodePlugin.isLegacyV01(try store.boundedString(at: url, maximum: 128 * 1_024))
    }

    func isPreviousPlugin(at url: URL) throws -> Bool {
        guard store.itemExists(at: url), try store.regularFile(at: url) else { return false }
        return OpenCodePlugin.isPreviousVersion(try store.boundedString(at: url, maximum: 128 * 1_024))
    }

    func isOwnedHelper() throws -> Bool {
        guard
            store.itemExists(at: paths.installedHook),
            try store.regularFile(at: paths.installedHook),
            try isOwnedHelperMarker()
        else { return false }
        return true
    }

    func isCurrentOwnedHelper() throws -> Bool {
        guard store.itemExists(at: paths.installedHook), try store.regularFile(at: paths.installedHook),
              store.itemExists(at: paths.helperOwnership),
              try store.regularFile(at: paths.helperOwnership) else { return false }
        return try store.boundedString(at: paths.helperOwnership, maximum: 128)
            == NotchBotIntegrationFiles.helperOwnershipMarker
    }

    func isOwnedHelperMarker() throws -> Bool {
        guard store.itemExists(at: paths.helperOwnership),
              try store.regularFile(at: paths.helperOwnership) else {
            return false
        }
        let marker = try store.boundedString(at: paths.helperOwnership, maximum: 128)
        return marker == NotchBotIntegrationFiles.helperOwnershipMarker
            || NotchBotIntegrationFiles.previousHelperOwnershipMarkers.contains(marker)
    }

    func isPreviousHelperMarker() throws -> Bool {
        guard store.itemExists(at: paths.helperOwnership),
              try store.regularFile(at: paths.helperOwnership) else {
            return false
        }
        return NotchBotIntegrationFiles.previousHelperOwnershipMarkers.contains(
            try store.boundedString(at: paths.helperOwnership, maximum: 128)
        )
    }

    func isOwnedInstallStatus() throws -> Bool {
        guard store.itemExists(at: paths.installStatus),
              try store.regularFile(at: paths.installStatus) else {
            return false
        }
        let data = try store.boundedData(at: paths.installStatus, maximum: 4_096)
        guard let version = try? JSONDecoder().decode(IntegrationInstallStatus.self, from: data).version else {
            return false
        }
        return (2...IntegrationInstallStatus.currentVersion).contains(version)
    }

    func isCurrentInstallationMarked() -> Bool {
        guard
            let data = try? store.boundedData(at: paths.installStatus, maximum: 4_096),
            (try? JSONDecoder().decode(IntegrationInstallStatus.self, from: data).version)
                == IntegrationInstallStatus.currentVersion
        else { return false }
        return true
    }

    func hasManagedClaudeHooks() throws -> Bool {
        guard store.itemExists(at: paths.claudeSettings),
              try store.regularFile(at: paths.claudeSettings) else {
            return false
        }
        let data = try store.boundedData(at: paths.claudeSettings, maximum: 4 * 1_024 * 1_024)
        return ClaudeHooks.containsManagedHandlers(
            in: try store.decodeJSONObject(data),
            hookPath: paths.installedHook.path
        )
    }

    func hasOutdatedInstallation() throws -> Bool {
        if store.itemExists(at: paths.openCodePlugin),
           try isLegacyPlugin(at: paths.openCodePlugin) || isPreviousPlugin(at: paths.openCodePlugin) {
            return true
        }
        if store.itemExists(at: paths.installStatus) {
            let data = try store.boundedData(at: paths.installStatus, maximum: 4_096)
            if let version = try? JSONDecoder().decode(IntegrationInstallStatus.self, from: data).version,
               (2..<IntegrationInstallStatus.currentVersion).contains(version) { return true }
        }
        if store.itemExists(at: paths.helperOwnership), try isPreviousHelperMarker() { return true }
        return try hasManagedClaudeHooks() && !isCurrentInstallationMarked()
    }

    func canReplaceOutdatedHelper() throws -> Bool {
        if store.itemExists(at: paths.helperOwnership), try isOwnedHelperMarker() {
            return true
        }
        guard store.itemExists(at: paths.openCodePlugin),
              try isLegacyPlugin(at: paths.openCodePlugin) else {
            return false
        }
        return try hasManagedClaudeHooks()
    }

    func validateManagedDestinations(allowLegacyUpdate: Bool, allowHelperUpdate: Bool) throws {
        if store.itemExists(at: paths.openCodePlugin) {
            let owned = try isOwnedPlugin(at: paths.openCodePlugin)
            let legacy = allowLegacyUpdate
                ? try isLegacyPlugin(at: paths.openCodePlugin)
                    || isPreviousPlugin(at: paths.openCodePlugin)
                : false
            guard owned || legacy else {
                throw IntegrationError.unrelatedManagedFile(paths.openCodePlugin.path)
            }
        }
        if store.itemExists(at: paths.installedHook) {
            guard (try isOwnedHelper()) || allowHelperUpdate else {
                throw IntegrationError.unrelatedManagedFile(paths.installedHook.path)
            }
        }
        if store.itemExists(at: paths.helperOwnership), !(try isOwnedHelperMarker()) {
            throw IntegrationError.unrelatedManagedFile(paths.helperOwnership.path)
        }
        if store.itemExists(at: paths.installStatus), !(try isOwnedInstallStatus()) {
            throw IntegrationError.unrelatedManagedFile(paths.installStatus.path)
        }
    }

    func writeInstallStatus() throws {
        let data = try JSONEncoder().encode(IntegrationInstallStatus())
        try store.writeAtomically(data, to: paths.installStatus, permissions: 0o600)
    }

    func removeLegacyPrivacyPolicyIfOwned() throws {
        guard store.itemExists(at: paths.legacyPrivacyPolicy),
              try store.regularFile(at: paths.legacyPrivacyPolicy) else {
            return
        }
        guard let data = try? store.boundedData(at: paths.legacyPrivacyPolicy, maximum: 4_096) else { return }
        guard LegacyIntegrationPrivacyPolicy.recognizes(data) else { return }
        try store.fileManager.removeItem(at: paths.legacyPrivacyPolicy)
    }
}
