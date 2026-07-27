import Darwin
import Foundation
import NotchBotCore

final class EventServer {
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    func start(handler: @escaping (Data) -> Void) throws {
        let supportDirectory = NotchBotPaths.applicationSupportDirectory
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        unlink(NotchBotPaths.socketPath)

        descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }

        var address = try UnixDatagramClient.socketAddress(path: NotchBotPaths.socketPath)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(
                    descriptor,
                    socketPointer,
                    UnixDatagramClient.socketLength(for: NotchBotPaths.socketPath)
                )
            }
        }
        guard result == 0 else {
            close(descriptor)
            descriptor = -1
            throw CocoaError(.fileWriteUnknown)
        }
        chmod(NotchBotPaths.socketPath, S_IRUSR | S_IWUSR)

        let dispatchSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .userInitiated))
        dispatchSource.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = recv(self.descriptor, &buffer, buffer.count, 0)
            if count > 0 {
                handler(Data(buffer.prefix(count)))
            }
        }
        dispatchSource.setCancelHandler { [descriptor] in
            close(descriptor)
            unlink(NotchBotPaths.socketPath)
        }
        source = dispatchSource
        dispatchSource.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    deinit {
        stop()
    }
}
