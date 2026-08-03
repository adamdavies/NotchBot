import Foundation
import Testing
@testable import NotchBotIntegrationCore

/// The plugin is assembled from a template rather than emitted by a JS toolchain, so a stray
/// edit can ship syntactically invalid JavaScript. Skipped when no `node` is on PATH.
@Test func generatedPluginIsSyntacticallyValidJavaScript() throws {
    guard let node = nodeExecutable() else { return }
    for includeCostTracking in [false, true] {
        let plugin = OpenCodePlugin.generate(
            hookPath: "/tmp/notchbot-hook",
            includeCostTracking: includeCostTracking
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchbot-plugin-\(UUID().uuidString).mjs")
        try plugin.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = node
        process.arguments = ["--check", url.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let diagnostic = "node --check rejected the generated plugin "
            + "(cost tracking: \(includeCostTracking)): "
            + String(decoding: errorOutput, as: UTF8.self)
        #expect(process.terminationStatus == 0, Comment(rawValue: diagnostic))
    }
}

private func nodeExecutable() -> URL? {
    for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    where FileManager.default.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
    }
    return nil
}
