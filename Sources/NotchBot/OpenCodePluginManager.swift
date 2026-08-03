import Foundation
import NotchBotIntegrationCore

/// Writes `~/.config/opencode/plugins/notchbot.js`. Both installation and the cost-tracking toggle
/// regenerate the plugin, so generation lives here rather than in either caller.
struct OpenCodePluginManager {
    let store: ManagedFileStore
    let paths: IntegrationPaths
    let ownership: IntegrationOwnership

    func install(hookURL: URL, includeCostTracking: Bool, allowLegacyUpdate: Bool) throws {
        if store.itemExists(at: paths.openCodePlugin) {
            let replaceable = try ownership.isOwnedPlugin(at: paths.openCodePlugin)
                || (allowLegacyUpdate && (ownership.isLegacyPlugin(at: paths.openCodePlugin)
                    || ownership.isPreviousPlugin(at: paths.openCodePlugin)))
            guard replaceable else {
                throw IntegrationError.unrelatedManagedFile(paths.openCodePlugin.path)
            }
        }
        try write(hookURL: hookURL, includeCostTracking: includeCostTracking)
    }

    func write(hookURL: URL, includeCostTracking: Bool) throws {
        try store.fileManager.createDirectory(
            at: paths.openCodePlugin.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plugin = OpenCodePlugin.generate(
            hookPath: hookURL.path,
            includeCostTracking: includeCostTracking
        )
        try store.writeAtomically(Data(plugin.utf8), to: paths.openCodePlugin, permissions: 0o600)
    }
}
