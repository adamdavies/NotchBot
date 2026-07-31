import Foundation

public struct StatusLineWrapperState: Codable, Equatable, Sendable {
    public let marker: String
    public let originalStatusLineJSON: Data?

    public init(originalStatusLineJSON: Data?) {
        marker = NotchBotIntegrationFiles.generatedMarker
        self.originalStatusLineJSON = originalStatusLineJSON
    }

    public var isOwned: Bool {
        marker == NotchBotIntegrationFiles.generatedMarker
            || NotchBotIntegrationFiles.previousGeneratedMarkers.contains(marker)
    }
}

public enum StatusLineWrapper {
    public static func command(wrapperPath: String) -> String {
        shellEscaped(wrapperPath)
    }

    public static func referencesWrapper(_ command: String, atPath wrapperPath: String) -> Bool {
        command.contains(wrapperPath)
    }

    public static func generate(hookPath: String, existingCommand: String?) -> String {
        let escapedHookPath = shellEscaped(hookPath)
        let header = """
            #!/bin/bash
            # NotchBot cost tracking wrapper.
            # This script forwards Claude Code's status line data to NotchBot
            # for estimated cost tracking, then passes it to your status line
            # command. To disable, toggle off cost tracking in NotchBot's menu,
            # or replace this command in ~/.claude/settings.json with your own.
            # \(NotchBotIntegrationFiles.generatedMarker). Do not edit.
            """
        let body: String
        if let existingCommand, !existingCommand.isEmpty {
            let escapedExisting = shellEscaped(existingCommand)
            body = """
                input_file=$(mktemp) || exit 1
                chmod 600 "$input_file"
                trap 'rm -f "$input_file"' EXIT
                cat > "$input_file"
                \(escapedHookPath) --source claude --kind metadata --mode statusline < "$input_file" &
                original_command=\(escapedExisting)
                /bin/sh -c "$original_command" < "$input_file"
                """
        } else {
            body = """
                cat | \(escapedHookPath) --source claude --kind metadata --mode statusline
                """
        }
        return (header + "\n" + body)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                return String(trimmed)
            }
            .joined(separator: "\n")
            + "\n"
    }

    public static func isOwned(_ contents: String) -> Bool {
        contents.contains(NotchBotIntegrationFiles.generatedMarker)
            && contents.contains("--mode statusline")
    }

    public static func isPreviousVersion(_ contents: String) -> Bool {
        NotchBotIntegrationFiles.previousGeneratedMarkers.contains { contents.contains($0) }
            && contents.contains("--mode statusline")
    }

    public static func extractChainedCommand(_ contents: String) -> String? {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let prefix = "original_command="
        guard let assignmentLine = lines.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        let value = String(assignmentLine.dropFirst(prefix.count))
        let unquoted = value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2
            ? String(value.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
            : value
        return unquoted.isEmpty ? nil : unquoted
    }

    private static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
