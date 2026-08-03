import Foundation
import NotchBotIntegrationCore

/// Owns every change to `~/.claude/settings.json`. Replacement is transactional: back up, verify
/// the file has not changed underneath, write, verify the result, then drop the backup.
struct ClaudeSettingsManager {
    let store: ManagedFileStore
    let paths: IntegrationPaths
    let makeUUID: () -> UUID

    func updateManagedHooks(install: Bool) throws {
        let settingsURL = paths.claudeSettings
        if !install && !store.itemExists(at: settingsURL) { return }
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
        let originalSettings = try store.decodeJSONObject(originalData)
        let updatedSettings = install
            ? ClaudeHooks.merging(into: originalSettings, hookPath: paths.installedHook.path)
            : ClaudeHooks.removing(from: originalSettings, hookPath: paths.installedHook.path)
        try replace(originalData: originalData, originalMode: originalMode, with: updatedSettings)
    }

    func replace(
        originalData: Data,
        originalMode: Int,
        with updatedSettings: [String: Any]
    ) throws {
        let settingsURL = paths.claudeSettings
        let updatedData = try JSONSerialization.data(
            withJSONObject: updatedSettings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )

        let backupURL = try createBackup(data: originalData)
        do {
            let currentSnapshot = store.itemExists(at: settingsURL)
                ? try store.boundedSnapshot(at: settingsURL, maximum: 4 * 1_024 * 1_024)
                : nil
            guard currentSnapshot?.data ?? Data() == originalData else {
                throw IntegrationError.concurrentSettingsChange
            }
            try store.writeAtomically(
                updatedData,
                to: settingsURL,
                permissions: originalMode,
                expectation: currentSnapshot.map { .identity($0.identity) } ?? .absent
            )
            let verification = try store.decodeJSONObject(
                store.boundedData(at: settingsURL, maximum: 4 * 1_024 * 1_024)
            )
            let expected = try store.decodeJSONObject(updatedData)
            guard NSDictionary(dictionary: verification).isEqual(to: expected) else {
                throw IntegrationError.settingsVerificationFailed
            }
            try store.fileManager.removeItem(at: backupURL)
        } catch {
            // The restrictive backup remains in NotchBot Application Support for recovery.
            throw error
        }
    }

    func removeOwnedBackups() throws {
        let directory = paths.backupDirectory
        guard try store.privateDirectory(at: directory) else { return }
        let entries = try store.fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for entry in entries where Self.isSettingsBackup(entry) {
            guard try store.regularFile(at: entry) else { continue }
            try store.fileManager.removeItem(at: entry)
        }
        if try store.fileManager.contentsOfDirectory(atPath: directory.path).isEmpty {
            try store.fileManager.removeItem(at: directory)
        }
    }

    private func createBackup(data: Data) throws -> URL {
        let directory = paths.backupDirectory
        try store.fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try store.secureDirectory(directory, permissions: 0o700)
        let url = directory.appendingPathComponent("claude-settings-\(makeUUID().uuidString).backup")
        try store.writeAtomically(data, to: url, permissions: 0o600)
        try pruneBackups(preserving: url)
        return url
    }

    /// Keeps the five newest recognized backups. Unrelated files, directories, and symlinks in the
    /// folder are never pruned.
    private func pruneBackups(preserving current: URL) throws {
        let directory = current.deletingLastPathComponent()
        let entries = try store.fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        let backups = try entries.filter {
            guard Self.isSettingsBackup($0) else { return false }
            return try store.regularFile(at: $0)
        }
        let newest = try backups.sorted {
            let left = try $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            let right = try $1.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
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
            try store.fileManager.removeItem(at: backup)
        }
    }

    static func isSettingsBackup(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let prefix = "claude-settings-"
        let suffix = ".backup"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let token = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard let uuid = UUID(uuidString: token) else { return false }
        return uuid.uuidString == token
    }
}
