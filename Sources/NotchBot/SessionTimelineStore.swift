import Foundation
import NotchBotCore

/// The persistence seam `ActivityModel` depends on, so tests can drive load, save, and failure
/// without touching the filesystem. Main-actor bound because the model that owns it is.
@MainActor
protocol SessionTimelineStoring {
    /// Returns the stored timeline when it belongs to `day`. A document for an earlier day, an
    /// unsupported version, or unreadable content is discarded and reported as absent.
    func load(day: String) throws -> SessionTimelineDocument?
    func save(_ document: SessionTimelineDocument) throws
    /// Deletes the stored timeline. Used by the daily rollover and after integration removal.
    func removeAll() throws
}

/// Reads and writes `session-timeline.json` in NotchBot's Application Support directory through the
/// same bounded, symlink-refusing, permission-preserving path as every other managed file.
struct SessionTimelineStore: SessionTimelineStoring {
    /// Twice the document's own encoded bound, so a file that is merely at the limit still loads and
    /// only a genuinely oversized one is rejected.
    static let maximumFileBytes = SessionTimelineDocument.maximumEncodedBytes * 2

    let store: ManagedFileStore
    let supportDirectory: URL
    let url: URL

    init(store: ManagedFileStore, paths: IntegrationPaths) {
        self.store = store
        supportDirectory = paths.applicationSupportDirectory
        url = paths.sessionTimeline
    }

    static var live: SessionTimelineStore {
        let fileManager = FileManager.default
        return SessionTimelineStore(
            store: ManagedFileStore(fileManager: fileManager, fileWriter: SecureAtomicFileWriter()),
            paths: IntegrationPaths(
                homeDirectory: fileManager.homeDirectoryForCurrentUser,
                applicationSupportDirectory: NotchBotPaths.applicationSupportDirectory
            )
        )
    }

    func load(day: String) throws -> SessionTimelineDocument? {
        guard try store.regularFile(at: url) else {
            // Absent is the normal first-run case. Present but not a user-owned regular file belongs
            // to someone else: refuse it, and never delete it.
            guard store.itemExists(at: url) else { return nil }
            throw IntegrationError.invalidManagedFile(url.path)
        }
        let data: Data
        do {
            data = try store.boundedData(at: url, maximum: Self.maximumFileBytes)
        } catch IntegrationError.managedFileTooLarge {
            try discard()
            return nil
        }
        guard let decoded = try? SessionTimelineDocument.decoder()
            .decode(SessionTimelineDocument.self, from: data),
            decoded.version == SessionTimelineDocument.currentVersion,
            decoded.day == day else {
            // Our own file, and no longer usable — a stale day, a version this build does not know,
            // or corrupt content. Removing it lets the app recover instead of failing every load.
            try discard()
            return nil
        }
        // Decoding bypasses the initializer, so ordering and both bounds are reapplied here rather
        // than trusted from the file.
        return SessionTimelineDocument(day: decoded.day, sessions: decoded.sessions)
    }

    func save(_ document: SessionTimelineDocument) throws {
        try store.preparePrivateSupportDirectory(supportDirectory)
        try store.writeAtomically(document.encoded(), to: url, permissions: 0o600)
    }

    func removeAll() throws {
        try discard()
    }

    private func discard() throws {
        try store.removeRegularFile(at: url)
    }
}
