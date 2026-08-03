import Foundation
import NotchBotCore

/// The side effects the hook performs, injected so the run loop can be exercised in tests.
public protocol PermissionResponding: AnyObject {
    var responseToken: String { get }
    func start() throws
    func receive(timeout: TimeInterval) throws -> AgentPermissionDecision?
    func stop()
}

extension PermissionResponseServer: PermissionResponding {}

public struct HookServices: Sendable {
    public var readInput: @Sendable (Int) -> Data
    public var send: @Sendable (Data) throws -> Void
    public var makePermissionServer: @Sendable () -> PermissionResponding
    public var writeOutput: @Sendable (Data) -> Void
    public var writeError: @Sendable (Data) -> Void

    public init(
        readInput: @escaping @Sendable (Int) -> Data,
        send: @escaping @Sendable (Data) throws -> Void,
        makePermissionServer: @escaping @Sendable () -> PermissionResponding,
        writeOutput: @escaping @Sendable (Data) -> Void,
        writeError: @escaping @Sendable (Data) -> Void
    ) {
        self.readInput = readInput
        self.send = send
        self.makePermissionServer = makePermissionServer
        self.writeOutput = writeOutput
        self.writeError = writeError
    }

    public static let live = HookServices(
        readInput: { FileHandle.standardInput.readData(ofLength: $0) },
        send: { try UnixDatagramClient.send($0) },
        makePermissionServer: { PermissionResponseServer() },
        writeOutput: { FileHandle.standardOutput.write($0) },
        writeError: { FileHandle.standardError.write($0) }
    )
}
