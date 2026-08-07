import Foundation
import NotchBotCore
import NotchBotIntegrationCore
import ServiceManagement

/// Coordinates integration installation, update, and removal. The filesystem, ownership, Claude
/// settings, plugin, and cost-tracking concerns each live in their own type; this drives them and
/// owns the published status the UI binds to.
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
    @Published private(set) var isInstalled = false
    @Published private(set) var costTrackingEnabled: Bool

    private let environment: Environment
    private let paths: IntegrationPaths
    private let store: ManagedFileStore
    private let ownership: IntegrationOwnership
    private let settings: ClaudeSettingsManager
    private let plugin: OpenCodePluginManager
    private let costTracking: CostTrackingManager

    private var fileManager: FileManager { environment.fileManager }

    init(environment: Environment = .live) {
        self.environment = environment
        let paths = IntegrationPaths(
            homeDirectory: environment.homeDirectory,
            applicationSupportDirectory: environment.applicationSupportDirectory
        )
        let store = ManagedFileStore(
            fileManager: environment.fileManager,
            fileWriter: environment.fileWriter
        )
        let ownership = IntegrationOwnership(store: store, paths: paths)
        let settings = ClaudeSettingsManager(
            store: store,
            paths: paths,
            makeUUID: environment.makeUUID
        )
        let plugin = OpenCodePluginManager(store: store, paths: paths, ownership: ownership)
        self.paths = paths
        self.store = store
        self.ownership = ownership
        self.settings = settings
        self.plugin = plugin
        costTracking = CostTrackingManager(
            store: store,
            paths: paths,
            ownership: ownership,
            settings: settings,
            plugin: plugin
        )
        costTrackingEnabled = environment.defaults.bool(forKey: DailyCostPreference.trackingEnabledKey)
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
            let pluginExists = store.itemExists(at: paths.openCodePlugin)
            let pluginIsLegacy = pluginExists
                ? try ownership.isLegacyPlugin(at: paths.openCodePlugin)
                    || ownership.isPreviousPlugin(at: paths.openCodePlugin)
                : false
            let claudeIsLegacy = try ownership.hasManagedClaudeHooks()
            let pluginIsOwned = pluginExists ? try ownership.isOwnedPlugin(at: paths.openCodePlugin) : false
            if pluginExists && !pluginIsOwned && !pluginIsLegacy {
                throw IntegrationError.unrelatedManagedFile(paths.openCodePlugin.path)
            }
            let helperExists = store.itemExists(at: paths.installedHook)
            let helperIsOwned = helperExists ? try ownership.isOwnedHelper() : false
            if helperExists && !helperIsOwned && !pluginIsLegacy && !claudeIsLegacy {
                throw IntegrationError.unrelatedManagedFile(paths.installedHook.path)
            }
            if store.itemExists(at: paths.helperOwnership), !(try ownership.isOwnedHelperMarker()) {
                throw IntegrationError.unrelatedManagedFile(paths.helperOwnership.path)
            }
            if store.itemExists(at: paths.installStatus), !(try ownership.isOwnedInstallStatus()) {
                throw IntegrationError.unrelatedManagedFile(paths.installStatus.path)
            }
            // Checked before anything changes: a timeline destination that has been replaced with a
            // symlink or another user's file must abort the whole removal rather than leave the
            // integrations half-removed.
            let timelineIsRemovable = try store.removableRegularFile(at: paths.sessionTimeline)

            if costTrackingEnabled || store.itemExists(at: paths.statusLineState) {
                try costTracking.disable(updatePlugin: false)
                clearCostTrackingPreferences()
            }

            try settings.updateManagedHooks(install: false)
            if pluginExists { try fileManager.removeItem(at: paths.openCodePlugin) }
            if store.itemExists(at: paths.installedHook) {
                try fileManager.removeItem(at: paths.installedHook)
            }
            if store.itemExists(at: paths.helperOwnership) {
                try fileManager.removeItem(at: paths.helperOwnership)
            }
            try settings.removeOwnedBackups()
            if store.itemExists(at: paths.installStatus) {
                try fileManager.removeItem(at: paths.installStatus)
            }
            try ownership.removeLegacyPrivacyPolicyIfOwned()
            // Removed last, after every ownership check has passed. The timeline is the only managed
            // file holding task labels, so removing the integrations must take it with them.
            if timelineIsRemovable {
                try store.removeRegularFile(at: paths.sessionTimeline)
            }
            message = "Integrations removed"
            costTrackingEnabled = false
            requiresUpdate = false
            isInstalled = false
            // Drops the in-memory copy too. Posted only on success, so a failed removal leaves the
            // rows on screen matching what is still on disk.
            NotificationCenter.default.post(
                name: .notchBotIntegrationsRemoved,
                object: environment.defaults
            )
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
            guard store.itemExists(at: paths.installedHook),
                  store.itemExists(at: paths.openCodePlugin) else {
                message = "Install integrations first"
                return
            }
            try costTracking.enable()
            environment.defaults.set(true, forKey: DailyCostPreference.trackingEnabledKey)
            costTrackingEnabled = true
            NotificationCenter.default.post(
                name: .notchBotCostTrackingEnabled,
                object: environment.defaults
            )
            message = "Usage and cost tracking enabled"
        } catch {
            if (try? ownership.isOwnedPlugin(at: paths.openCodePlugin)) == true {
                try? plugin.write(hookURL: paths.installedHook, includeCostTracking: false)
            }
            costTracking.cleanupIncompleteFiles()
            message = "Usage and cost tracking failed: \(error.localizedDescription)"
        }
    }

    func disableCostTracking() {
        do {
            try costTracking.disable()
            clearCostTrackingPreferences()
            costTrackingEnabled = false
            message = "Usage and cost tracking disabled"
        } catch {
            message = "Disable usage and cost tracking failed: \(error.localizedDescription)"
        }
    }

    private func clearCostTrackingPreferences() {
        environment.defaults.set(false, forKey: DailyCostPreference.trackingEnabledKey)
        DailyCostPreference.clear(from: environment.defaults)
        NotificationCenter.default.post(
            name: .notchBotCostTrackingDisabled,
            object: environment.defaults
        )
    }

    private func performInstallation(allowLegacyUpdate: Bool) {
        do {
            try store.preparePrivateSupportDirectory(paths.applicationSupportDirectory)
            let outdated = try ownership.hasOutdatedInstallation()
            if outdated && !allowLegacyUpdate { throw IntegrationError.explicitUpdateRequired }
            let helperUpdateAllowed = if allowLegacyUpdate && outdated {
                try ownership.canReplaceOutdatedHelper()
            } else {
                false
            }
            try ownership.validateManagedDestinations(
                allowLegacyUpdate: allowLegacyUpdate && outdated,
                allowHelperUpdate: helperUpdateAllowed
            )
            let hookURL = try installHookExecutable(allowLegacyUpdate: helperUpdateAllowed)
            try plugin.install(
                hookURL: hookURL,
                includeCostTracking: costTrackingEnabled,
                allowLegacyUpdate: allowLegacyUpdate && outdated
            )
            try settings.updateManagedHooks(install: true)
            if costTrackingEnabled {
                try costTracking.enable()
            }
            try ownership.writeInstallStatus()
            try ownership.removeLegacyPrivacyPolicyIfOwned()
            message = "OpenCode and Claude Code connected"
            requiresUpdate = false
            isInstalled = true
        } catch {
            message = "Installation failed: \(error.localizedDescription)"
        }
    }

    private func refreshStatus() {
        guard
            let data = try? store.boundedData(at: paths.installStatus, maximum: 4_096),
            let status = try? JSONDecoder().decode(IntegrationInstallStatus.self, from: data),
            status.version == IntegrationInstallStatus.currentVersion,
            (try? ownership.isCurrentOwnedHelper()) == true,
            (try? ownership.isOwnedPlugin(at: paths.openCodePlugin)) == true
        else {
            if store.itemExists(at: paths.installedHook) || store.itemExists(at: paths.openCodePlugin) {
                message = "Integration update required"
                requiresUpdate = true
            }
            isInstalled = false
            return
        }
        message = "Integration files installed"
        requiresUpdate = false
        isInstalled = true
    }

    private func installHookExecutable(allowLegacyUpdate: Bool) throws -> URL {
        let destination = paths.installedHook
        try store.preparePrivateSupportDirectory(paths.applicationSupportDirectory)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try store.secureDirectory(destination.deletingLastPathComponent(), permissions: 0o700)
        if store.itemExists(at: destination) {
            guard (try ownership.isOwnedHelper()) || allowLegacyUpdate else {
                throw IntegrationError.unrelatedManagedFile(destination.path)
            }
        }
        if store.itemExists(at: paths.helperOwnership),
           !(try store.regularFile(at: paths.helperOwnership)) {
            throw IntegrationError.unrelatedManagedFile(paths.helperOwnership.path)
        }
        guard let source = environment.bundledHookExecutable else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "notchbot-hook"])
        }

        try store.writeAtomically(Data(contentsOf: source), to: destination, permissions: 0o700)
        try store.writeAtomically(
            Data(NotchBotIntegrationFiles.helperOwnershipMarker.utf8),
            to: paths.helperOwnership,
            permissions: 0o600
        )
        return destination
    }
}
