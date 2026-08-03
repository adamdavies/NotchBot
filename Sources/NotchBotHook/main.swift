import Foundation
import NotchBotHookCore

exit(HookRunner.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment
))
