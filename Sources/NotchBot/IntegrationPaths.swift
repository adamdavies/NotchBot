import Foundation
import NotchBotIntegrationCore

/// Every filesystem location the integration owns, derived from one home and one Application
/// Support directory so tests can redirect the whole set at once.
struct IntegrationPaths {
    let homeDirectory: URL
    let applicationSupportDirectory: URL

    var installedHook: URL {
        applicationSupportDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("notchbot-hook")
    }

    var helperOwnership: URL {
        NotchBotIntegrationFiles.helperOwnershipURL(helperURL: installedHook)
    }

    var openCodePlugin: URL {
        homeDirectory
            .appendingPathComponent(".config/opencode/plugins", isDirectory: true)
            .appendingPathComponent("notchbot.js")
    }

    var claudeSettings: URL {
        homeDirectory.appendingPathComponent(".claude/settings.json")
    }

    var statusLineWrapper: URL {
        applicationSupportDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("notchbot-statusline")
    }

    var statusLineState: URL {
        applicationSupportDirectory.appendingPathComponent("statusline-state.json")
    }

    /// Today's completed sessions. The only NotchBot state that outlives the process and carries
    /// bounded task labels, so it is removed with the integrations.
    var sessionTimeline: URL {
        applicationSupportDirectory.appendingPathComponent("session-timeline.json")
    }

    var installStatus: URL {
        NotchBotIntegrationFiles.installStatusURL(
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    var backupDirectory: URL {
        NotchBotIntegrationFiles.backupDirectoryURL(
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    var legacyPrivacyPolicy: URL {
        applicationSupportDirectory.appendingPathComponent("integration-privacy.json")
    }
}

struct ManagedFileSnapshot {
    let data: Data
    let identity: AtomicFileIdentity
}

enum IntegrationError: LocalizedError {
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
