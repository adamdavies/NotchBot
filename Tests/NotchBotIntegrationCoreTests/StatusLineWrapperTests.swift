import Foundation
import Testing
@testable import NotchBotIntegrationCore

@Test func statusLineWrapperPreservesShellCommandSemantics() throws {
    let script = StatusLineWrapper.generate(
        hookPath: "/usr/bin/true",
        existingCommand: "tr a-z A-Z | sed 's/HELLO/WORKS/'"
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", script]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output

    try process.run()
    input.fileHandleForWriting.write(Data("hello\n".utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == "WORKS\n")
}

@Test func statusLineStateRetainsOriginalConfiguration() throws {
    let original = try JSONSerialization.data(withJSONObject: [
        "type": "command",
        "command": "~/statusline.sh --compact",
        "padding": 2,
        "refreshInterval": 5,
    ], options: [.sortedKeys])
    let state = StatusLineWrapperState(originalStatusLineJSON: original)
    let decoded = try JSONDecoder().decode(
        StatusLineWrapperState.self,
        from: JSONEncoder().encode(state)
    )

    #expect(decoded.isOwned)
    #expect(decoded.originalStatusLineJSON == original)
}
