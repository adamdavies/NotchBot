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

@Test func statusLineWrapperExtractsChainedCommand() {
    let script = StatusLineWrapper.generate(
        hookPath: "/tmp/hook",
        existingCommand: "bash '/Users/test/.claude/statusline-command.sh'"
    )
    let extracted = StatusLineWrapper.extractChainedCommand(script)
    #expect(extracted == "bash '/Users/test/.claude/statusline-command.sh'")

    let noChain = StatusLineWrapper.generate(hookPath: "/tmp/hook", existingCommand: nil)
    #expect(StatusLineWrapper.extractChainedCommand(noChain) == nil)

    let withQuotes = StatusLineWrapper.generate(hookPath: "/tmp/hook", existingCommand: "echo 'hello world'")
    #expect(StatusLineWrapper.extractChainedCommand(withQuotes) == "echo 'hello world'")
}

@Test func statusLineWrapperDetectsRecursiveCommands() {
    let path = "/Users/test/Library/Application Support/NotchBot/bin/notchbot-statusline"

    #expect(StatusLineWrapper.referencesWrapper("bash '\(path)'", atPath: path))
    #expect(StatusLineWrapper.referencesWrapper("'\(path)'", atPath: path))
    #expect(!StatusLineWrapper.referencesWrapper("~/my-statusline.sh", atPath: path))
}
