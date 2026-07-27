import Foundation

public enum NotchBotPaths {
    public static var applicationSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchBot", isDirectory: true)
    }

    public static var socketPath: String {
        applicationSupportDirectory.appendingPathComponent("notchbot.sock").path
    }

    public static var installedHookURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("notchbot-hook")
    }
}
