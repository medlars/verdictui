import Darwin
import Foundation

/// Bounded socket client for persistent browser sessions across CLI invocations.
public enum DaemonClient {
    public enum Failure: Error, CustomStringConvertible {
        case unavailable(String)
        public var description: String {
            switch self { case .unavailable(let reason): return "daemon unavailable: \(reason)" }
        }
    }

    public static func send(_ request: DaemonRequest, socketPath: String) async throws -> DaemonResponse {
        let encoded = try VerdictOutput.encoder(pretty: false).encode(request) + Data([10])
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try exchange(encoded, path: socketPath)
                    continuation.resume(returning: try JSONDecoder().decode(DaemonResponse.self, from: data))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Start only this binary's daemon, preserving its injected registry.
    public static func ensureRunning(socketPath: String, executable: URL, stock: Bool = true) async throws {
        if DaemonTransport.isLive(path: socketPath) { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["daemon", "start", "--socket", socketPath]
        if stock {
            var environment = ProcessInfo.processInfo.environment
            environment["VERDICTUI_STOCK_DAEMON"] = "1"
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if DaemonTransport.isLive(path: socketPath) { return }
            guard process.isRunning else {
                // A simultaneous caller may have won the bind race.
                if DaemonTransport.isLive(path: socketPath) { return }
                throw Failure.unavailable("the server exited during startup")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { process.terminate() }
        throw Failure.unavailable("server startup timed out")
    }

    private static func exchange(_ data: Data, path: String) throws -> Data {
        var address = sockaddr_un()
        guard !path.utf8.contains(0), path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure.unavailable("socket path is invalid or too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.utf8CString.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unavailable("socket creation failed") }
        defer { close(fd) }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0 else {
            throw Failure.unavailable("cannot configure socket")
        }
        var timeout = timeval(tv_sec: 65, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard setsockopt(fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
                throw Failure.unavailable("cannot configure timeout")
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.unavailable("cannot connect to socket") }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.unavailable("request write failed") }
                offset += count
            }
        }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while received.count <= 8 * 1_024 * 1_024 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.unavailable("reply missing or timed out") }
            received.append(contentsOf: buffer.prefix(count))
            if let newline = received.firstIndex(of: 10) { return Data(received[..<newline]) }
        }
        throw Failure.unavailable("reply exceeds 8 MiB")
    }
}
