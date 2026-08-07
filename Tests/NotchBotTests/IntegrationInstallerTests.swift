import Darwin
import Foundation
import NotchBotIntegrationCore
import Testing
@testable import NotchBot

@MainActor
@Test func installerCleanInstallIsIdempotentAndPreservesClaudeSettings() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try fixture.writeSettings(["custom": ["enabled": true]])
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.settingsURL.path)
    let installer = fixture.installer()

    installer.install()
    #expect(installer.message == "OpenCode and Claude Code connected")
    #expect(try Data(contentsOf: fixture.helperURL) == fixture.helperData)
    #expect(try installerPermissions(of: fixture.helperURL) == 0o700)
    #expect(try installerPermissions(of: fixture.pluginURL) == 0o600)
    #expect(try installerPermissions(of: fixture.settingsURL) == 0o640)
    #expect(try fixture.settings()["custom"] as? [String: Bool] == ["enabled": true])
    #expect(ClaudeHooks.containsManagedHandlers(in: try fixture.settings(), hookPath: fixture.helperURL.path))

    installer.install()
    #expect(installer.message == "OpenCode and Claude Code connected")
    #expect(try fixture.backupNames().isEmpty)
}

@MainActor
@Test func installerRequiresExplicitUpdateAndMigratesPreviousRevision() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let installer = fixture.installer()
    installer.install()
    #expect(installer.message == "OpenCode and Claude Code connected")

    let previousGeneratedMarker = try #require(NotchBotIntegrationFiles.previousGeneratedMarkers.first)
    let currentPlugin = try String(contentsOf: fixture.pluginURL, encoding: .utf8)
    try currentPlugin.replacingOccurrences(
        of: NotchBotIntegrationFiles.generatedMarker,
        with: previousGeneratedMarker
    ).write(to: fixture.pluginURL, atomically: true, encoding: .utf8)
    let previousHelperMarker = try #require(NotchBotIntegrationFiles.previousHelperOwnershipMarkers.first)
    try previousHelperMarker.write(to: fixture.helperOwnershipURL, atomically: true, encoding: .utf8)
    let previousStatus = "{\"version\":18,\"installedAt\":0}"
    try Data(previousStatus.utf8).write(to: fixture.installStatusURL)

    let updater = fixture.installer()
    updater.install()
    #expect(updater.message.contains("explicit update"))
    updater.updateIntegrations()

    #expect(updater.message == "OpenCode and Claude Code connected")
    #expect(OpenCodePlugin.isOwned(try String(contentsOf: fixture.pluginURL, encoding: .utf8)))
    #expect(try String(contentsOf: fixture.helperOwnershipURL, encoding: .utf8)
        == NotchBotIntegrationFiles.helperOwnershipMarker)
    let status = try JSONDecoder().decode(IntegrationInstallStatus.self, from: Data(contentsOf: fixture.installStatusURL))
    #expect(status.version == 21)
}

@MainActor
@Test func installerCostTrackingRoundTripRestoresCompleteStatusLine() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let originalStatusLine: [String: Any] = [
        "type": "command",
        "command": "custom-status --flag",
        "padding": 2,
    ]
    try fixture.writeSettings(["statusLine": originalStatusLine, "custom": true])
    let installer = fixture.installer()
    installer.install()

    installer.enableCostTracking()
    #expect(installer.message == "Usage and cost tracking enabled")
    let enabledStatusLine = try #require(try fixture.settings()["statusLine"] as? [String: Any])
    #expect(enabledStatusLine["command"] as? String != originalStatusLine["command"] as? String)

    installer.disableCostTracking()
    #expect(installer.message == "Usage and cost tracking disabled")
    let restored = try #require(try fixture.settings()["statusLine"] as? [String: Any])
    #expect(NSDictionary(dictionary: restored).isEqual(to: originalStatusLine))
    #expect(try fixture.settings()["custom"] as? Bool == true)
}

@MainActor
@Test(arguments: ["missing", "malformed"])
func disablingCostTrackingPreservesSettingsWithoutValidRecoveryState(stateCondition: String) throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let originalStatusLine: [String: Any] = [
        "type": "command",
        "command": "custom-status --flag",
    ]
    try fixture.writeSettings(["statusLine": originalStatusLine])
    let installer = fixture.installer()
    installer.install()
    installer.enableCostTracking()
    let enabledSettings = try Data(contentsOf: fixture.settingsURL)

    if stateCondition == "missing" {
        try FileManager.default.removeItem(at: fixture.statusLineStateURL)
    } else {
        try Data("not valid state".utf8).write(to: fixture.statusLineStateURL)
    }
    installer.disableCostTracking()

    #expect(installer.message.contains("Managed file is invalid"))
    #expect(try Data(contentsOf: fixture.settingsURL) == enabledSettings)
    #expect(installer.costTrackingEnabled)
}

@MainActor
@Test func uninstallValidatesOwnershipBeforeChangingCostTrackingSettings() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let originalStatusLine: [String: Any] = [
        "type": "command",
        "command": "custom-status --flag",
    ]
    try fixture.writeSettings(["statusLine": originalStatusLine])
    let installer = fixture.installer()
    installer.install()
    installer.enableCostTracking()
    let enabledSettings = try Data(contentsOf: fixture.settingsURL)
    try Data("unrelated".utf8).write(to: fixture.pluginURL)

    installer.uninstall()

    #expect(installer.message.contains("Refusing to replace"))
    #expect(try Data(contentsOf: fixture.settingsURL) == enabledSettings)
    #expect(try Data(contentsOf: fixture.pluginURL) == Data("unrelated".utf8))
    #expect(FileManager.default.fileExists(atPath: fixture.helperURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.statusLineStateURL.path))
    #expect(installer.costTrackingEnabled)
}

@MainActor
@Test func installerRefusesUnrelatedPluginAndUninstallsOwnedFiles() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.pluginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("unrelated".utf8).write(to: fixture.pluginURL)
    let refusing = fixture.installer()
    refusing.install()
    #expect(refusing.message.contains("Refusing to replace"))
    #expect(try Data(contentsOf: fixture.pluginURL) == Data("unrelated".utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.helperURL.path))

    try FileManager.default.removeItem(at: fixture.pluginURL)
    let installer = fixture.installer()
    installer.install()
    installer.uninstall()
    #expect(installer.message == "Integrations removed")
    #expect(!FileManager.default.fileExists(atPath: fixture.helperURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.pluginURL.path))
    #expect(!ClaudeHooks.containsManagedHandlers(in: try fixture.settings(), hookPath: fixture.helperURL.path))
}

@MainActor
@Test func installerRefusesSymlinkedClaudeSettings() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let target = fixture.root.appendingPathComponent("settings-target")
    try Data("{\"untouched\":true}".utf8).write(to: target)
    try FileManager.default.createDirectory(at: fixture.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: fixture.settingsURL, withDestinationURL: target)

    let installer = fixture.installer()
    installer.install()
    #expect(installer.message.contains("Claude settings must be a regular file"))
    #expect(try Data(contentsOf: target) == Data("{\"untouched\":true}".utf8))
}

@MainActor
@Test func failedSettingsReplacementRetainsOnlyFiveExactBackups() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try fixture.writeSettings(["custom": true])
    let unrelated = fixture.backupDirectory.appendingPathComponent("claude-settings-not-a-uuid.backup")
    try FileManager.default.createDirectory(at: fixture.backupDirectory, withIntermediateDirectories: true)
    try Data("unrelated".utf8).write(to: unrelated)
    let directoryEntry = fixture.backupDirectory.appendingPathComponent(
        "claude-settings-00000000-0000-0000-0000-000000000099.backup",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directoryEntry, withIntermediateDirectories: false)

    let writer = SelectiveFailingWriter(failingDestination: fixture.settingsURL)
    for index in 1 ... 7 {
        let installer = fixture.installer(
            makeUUID: { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))! },
            writer: writer
        )
        installer.install()
        #expect(installer.message.contains("Installation failed"))
    }

    #expect(try fixture.settings()["custom"] as? Bool == true)
    let backupNames = try fixture.backupNames()
    #expect(backupNames.count == 5, "Recognized backups: \(backupNames)")
    for backup in try fixture.backupURLs() {
        #expect(try installerPermissions(of: backup) == 0o600)
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Bool]
            == ["custom": true])
    }
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: directoryEntry.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
}

@MainActor
@Test func installerDoesNotOverwriteSettingsChangedAfterVerification() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try fixture.writeSettings(["original": true])
    let concurrentData = Data("{\"concurrent\":true}".utf8)
    let installer = fixture.installer(
        writer: MutatingSettingsWriter(
            settingsURL: fixture.settingsURL,
            concurrentData: concurrentData
        )
    )

    installer.install()

    #expect(installer.message.contains("Destination changed"))
    #expect(try Data(contentsOf: fixture.settingsURL) == concurrentData)
    #expect(try fixture.backupNames().count == 1)
}

private struct SelectiveFailingWriter: AtomicFileWriting {
    let failingDestination: URL
    let writer = SecureAtomicFileWriter()

    func write(
        _ data: Data,
        to destination: URL,
        permissions: mode_t,
        expectation: AtomicFileExpectation
    ) throws {
        if destination == failingDestination { throw CocoaError(.fileWriteUnknown) }
        try writer.write(data, to: destination, permissions: permissions, expectation: expectation)
    }
}

private struct MutatingSettingsWriter: AtomicFileWriting {
    let settingsURL: URL
    let concurrentData: Data
    let writer = SecureAtomicFileWriter()

    func write(
        _ data: Data,
        to destination: URL,
        permissions: mode_t,
        expectation: AtomicFileExpectation
    ) throws {
        if destination.lastPathComponent == settingsURL.lastPathComponent {
            try concurrentData.write(to: destination)
        }
        try writer.write(data, to: destination, permissions: permissions, expectation: expectation)
    }
}

private final class InstallerFixture {
    let root: URL
    let home: URL
    let support: URL
    let bundledHelper: URL
    let defaults: UserDefaults
    let defaultsSuiteName: String
    let helperData = Data("helper executable".utf8)

    init() throws {
        root = try installerTemporaryDirectory()
        home = root.appendingPathComponent("home", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        bundledHelper = root.appendingPathComponent("bundled-helper")
        defaultsSuiteName = "IntegrationInstallerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        try helperData.write(to: bundledHelper)
    }

    var helperURL: URL { support.appendingPathComponent("bin/notchbot-hook") }
    var pluginURL: URL { home.appendingPathComponent(".config/opencode/plugins/notchbot.js") }
    var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    var backupDirectory: URL { NotchBotIntegrationFiles.backupDirectoryURL(applicationSupportDirectory: support) }
    var helperOwnershipURL: URL { NotchBotIntegrationFiles.helperOwnershipURL(helperURL: helperURL) }
    var installStatusURL: URL { NotchBotIntegrationFiles.installStatusURL(applicationSupportDirectory: support) }
    var statusLineStateURL: URL { support.appendingPathComponent("statusline-state.json") }
    var sessionTimelineURL: URL { support.appendingPathComponent("session-timeline.json") }

    func writeSessionTimeline() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let payload = #"{"version":1,"day":"1-2026-8-7","sessions":[]}"#
        try Data(payload.utf8).write(to: sessionTimelineURL)
    }

    @MainActor func installer(
        makeUUID: @escaping () -> UUID = UUID.init,
        writer: any AtomicFileWriting = SecureAtomicFileWriter()
    ) -> IntegrationInstaller {
        IntegrationInstaller(environment: .init(
            fileManager: .default,
            homeDirectory: home,
            applicationSupportDirectory: support,
            defaults: defaults,
            bundledHookExecutable: bundledHelper,
            makeUUID: makeUUID,
            fileWriter: writer
        ))
    }

    func writeSettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: settingsURL)
    }

    func settings() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
    }

    func backupNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: backupDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: backupDirectory.path).filter {
            guard $0.hasPrefix("claude-settings-"),
                  UUID(uuidString: String($0.dropFirst(16).dropLast(7))) != nil else { return false }
            var info = stat()
            let path = backupDirectory.appendingPathComponent($0).path
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        }
    }

    func backupURLs() throws -> [URL] {
        try backupNames().map { backupDirectory.appendingPathComponent($0) }
    }

    func remove() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private func installerTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return url
}

private func installerPermissions(of url: URL) throws -> Int {
    let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    return value?.intValue ?? 0
}

@MainActor
@Test func installerReportsInstalledStateForTheMenuLabel() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let installer = fixture.installer()
    #expect(!installer.isInstalled)

    installer.install()
    #expect(installer.isInstalled)
    #expect(!installer.requiresUpdate)

    // A fresh installer reading the same on-disk state must agree, so the menu offers Reinstall.
    #expect(fixture.installer().isInstalled)

    installer.uninstall()
    #expect(!installer.isInstalled)
    #expect(!fixture.installer().isInstalled)
}

@MainActor
@Test func uninstallRemovesTheSessionTimeline() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let installer = fixture.installer()
    installer.install()
    try fixture.writeSessionTimeline()
    #expect(FileManager.default.fileExists(atPath: fixture.sessionTimelineURL.path))

    var removalNotifications = 0
    let observer = NotificationCenter.default.addObserver(
        forName: .notchBotIntegrationsRemoved,
        object: nil,
        queue: nil
    ) { _ in removalNotifications += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }

    installer.uninstall()

    #expect(installer.message == "Integrations removed")
    #expect(!FileManager.default.fileExists(atPath: fixture.sessionTimelineURL.path))
    #expect(removalNotifications == 1)
}

@MainActor
@Test func uninstallSucceedsWhenNoSessionTimelineWasEverWritten() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let installer = fixture.installer()
    installer.install()

    installer.uninstall()

    #expect(installer.message == "Integrations removed")
    #expect(!FileManager.default.fileExists(atPath: fixture.sessionTimelineURL.path))
}

@MainActor
@Test func uninstallRefusesAnUnsafeTimelineDestinationBeforeChangingAnything() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let installer = fixture.installer()
    installer.install()

    // The destination has been swapped for a link to a file outside NotchBot's state.
    let outside = fixture.root.appendingPathComponent("elsewhere")
    try Data("private".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: fixture.sessionTimelineURL, withDestinationURL: outside)

    var removalNotifications = 0
    let observer = NotificationCenter.default.addObserver(
        forName: .notchBotIntegrationsRemoved,
        object: nil,
        queue: nil
    ) { _ in removalNotifications += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }

    installer.uninstall()

    #expect(installer.message.hasPrefix("Removal failed"))
    #expect(removalNotifications == 0)
    // Nothing was followed, and nothing else was removed either — the integrations are intact.
    #expect(try Data(contentsOf: outside) == Data("private".utf8))
    #expect(FileManager.default.fileExists(atPath: fixture.helperURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.pluginURL.path))
    #expect(ClaudeHooks.containsManagedHandlers(in: try fixture.settings(), hookPath: fixture.helperURL.path))
    #expect(fixture.installer().isInstalled)
}
