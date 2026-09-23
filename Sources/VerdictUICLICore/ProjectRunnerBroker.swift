import CryptoKit
import Darwin
import Foundation

/// A process boundary, not a second verdict engine. The consumer keeps owning
/// its registry and all handlers; this broker owns stable transport and rebuilds.
public enum ProjectRunnerBroker {
    enum Wire { case mcp, daemon }

    public static func runIfDeclared() throws -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        let daemonAction = args.count > 1 && !args[1].hasPrefix("--") ? args[1] : "start"
        guard !ProjectRunner.isStockDaemon(arguments: args),
            args == ["mcp"]
                || (args.first == "daemon" && ["start", "stop", "status"].contains(daemonAction)),
            !args.contains("--help"), !args.contains("-h")
        else { return false }
        guard ProcessInfo.processInfo.environment[ProjectRunner.delegationMarker] == nil else {
            return false
        }
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let root = ProjectScenarios.findProjectRoot(startingAt: current),
            try ProjectScenarios.declaredRunnerStrict(projectRoot: root) != nil
        else { return false }
        let daemonPath = try daemonSocket(arguments: args, root: root)
        if args.first == "daemon", daemonAction == "stop" || daemonAction == "status" {
            // Stock-catalog control commands retain their original global daemon.
            guard try ProjectRunner.destination(
                startingAt: current,
                runningBinary: Bundle.main.executableURL
                    ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                alreadyDelegated: false) != nil else { return false }
            if daemonAction == "stop" {
                if FileManager.default.fileExists(atPath: daemonPath) {
                    try FileManager.default.removeItem(atPath: daemonPath)
                }
            } else {
                let report = try JSONSerialization.data(
                    withJSONObject: [
                        "running": DaemonTransport.isLive(path: daemonPath), "socket": daemonPath,
                    ], options: [.sortedKeys])
                FileHandle.standardOutput.write(report + Data([10]))
            }
            return true
        }
        try ProjectRunner.buildIfConfigured(projectRoot: root)
        guard
            let destination = try ProjectRunner.destination(
                startingAt: current,
                runningBinary: Bundle.main.executableURL
                    ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                alreadyDelegated: false)
        else { return false }
        let wire: Wire = args.first == "mcp" ? .mcp : .daemon
        let shutdown = Shutdown()
        let session = Session(
            destination: destination, wire: wire, shouldStop: { shutdown.stopped })
        defer {
            session.stop()
            shutdown.close()
        }
        if wire == .mcp {
            try serve(
                input: STDIN_FILENO, output: STDOUT_FILENO, session: session, shutdown: shutdown,
                persistent: true)
        } else {
            let path = daemonPath
            let listener = try DaemonTransport.prepare(path: path)
            defer {
                Darwin.close(listener)
                try? FileManager.default.removeItem(atPath: path)
            }
            while !shutdown.stopped && FileManager.default.fileExists(atPath: path) {
                var fd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&fd, 1, 200) > 0 else { continue }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                defer { Darwin.close(client) }
                try serve(
                    input: client, output: client, session: session, shutdown: shutdown,
                    persistent: false)
            }
        }
        return true
    }

    static func daemonSocket(arguments: [String], root: URL) throws -> String {
        var options = Array(arguments.dropFirst())
        if let action = options.first, ["start", "stop", "status"].contains(action) {
            options.removeFirst()
        }
        if options.isEmpty { return CommandEnvironment.daemonSocketPath(projectRoot: root) }
        if options.count == 2, options[0] == "--socket", !options[1].isEmpty,
            !options[1].hasPrefix("--") { return options[1] }
        if options.count == 1, options[0].hasPrefix("--socket="), options[0].count > 9 {
            return String(options[0].dropFirst(9))
        }
        throw Failure("invalid consumer daemon arguments; expected [start|stop|status] [--socket PATH]")
    }

    private static func serve(
        input: Int32, output: Int32, session: Session, shutdown: Shutdown, persistent: Bool
    ) throws {
        var pending = Data()
        while !shutdown.stopped {
            var fd = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, 200)
            if ready <= 0 {
                if !persistent { return }
                continue
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(input, &bytes, bytes.count)
            guard count > 0 else { return }
            pending.append(contentsOf: bytes.prefix(count))
            guard pending.count <= 1_048_576 else { return }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                if let response = session.answer(line) {
                    do { try writeAll(response, to: output) } catch { return }
                }
            }
        }
    }

    /// Serialized by the outer transport. Tests use actual child executables.
    // Recursive locking covers answer, fingerprint, stop and child observation;
    // teardown may arrive from a different executor after a request completes.
    final class Session: @unchecked Sendable {
        private let lock = NSRecursiveLock()
        let destination: ProjectRunner.Destination
        let wire: Wire
        let shouldStop: () -> Bool
        private var ownedChild: OwnedCommandProcess?
        var child: OwnedCommandProcess? {
            lock.lock()
            defer { lock.unlock() }
            return ownedChild
        }
        private var input: FileHandle?
        private var output: FileHandle?
        private var pending = Data()
        private var generation: String?
        private var initialization: Data?
        private var initialized: Data?
        private var socketPath: String?
        private var failedGeneration: String?
        private var failedAt: TimeInterval = 0
        typealias Build = (URL, () -> Bool) throws -> Void
        private let build: Build

        init(
            destination: ProjectRunner.Destination, wire: Wire,
            shouldStop: @escaping () -> Bool = { false }, build: Build? = nil
        ) {
            self.destination = destination
            self.wire = wire
            self.shouldStop = shouldStop
            self.build =
                build ?? { root, cancel in
                    try ProjectRunner.buildIfConfigured(projectRoot: root, shouldCancel: cancel)
                }
        }
        deinit { stop() }

        func answer(_ line: Data) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            let notification = wire == .mcp && object?["method"] is String && object?["id"] == nil
            do {
                guard let object, let method = object["method"] as? String else {
                    throw Failure("malformed request")
                }
                guard
                    try ProjectScenarios.declaredRunnerStrict(projectRoot: destination.projectRoot)?
                        .resolvingSymlinksInPath()
                        == destination.executable.resolvingSymlinksInPath()
                else {
                    throw Failure("consumer runner configuration changed; restart the broker")
                }
                let before = try fingerprint()
                let sourceBefore = try fingerprint(includeExecutable: false)
                if let child, try child.status() != nil {
                    stop()
                    throw Failure("consumer process exited; retry starts a fresh host")
                }
                if generation != before || child == nil {
                    stop()
                    if failedGeneration == before
                        && ProcessInfo.processInfo.systemUptime - failedAt < 1
                    {
                        throw Failure(
                            "consumer build unavailable; retry after editing or one second")
                    }
                    do {
                        try build(destination.projectRoot, shouldStop)
                    } catch {
                        failedGeneration = before
                        failedAt = ProcessInfo.processInfo.systemUptime
                        throw error
                    }
                    guard sourceBefore == (try fingerprint(includeExecutable: false)) else {
                        throw Failure("consumer changed during build; retry required")
                    }
                    try start()
                    generation = try fingerprint()
                    failedGeneration = nil
                    if wire == .mcp, method != "initialize", let initialization {
                        _ = try exchange(initialization, expectsReply: true)
                        if let initialized { _ = try exchange(initialized, expectsReply: false) }
                    }
                }
                let response = try exchange(line, expectsReply: !notification)
                guard generation == (try fingerprint()) else {
                    stop()
                    throw Failure("consumer changed during request; stale result discarded")
                }
                if wire == .mcp {
                    if method == "initialize" { initialization = line }
                    if method == "notifications/initialized" { initialized = line }
                }
                return response
            } catch {
                // Never replay a failed action: its side effects may have happened.
                stop()
                guard !notification else { return nil }
                return failure(line, reason: String(describing: error))
            }
        }

        func fingerprint(includeExecutable: Bool = true) throws -> String {
            lock.lock()
            defer { lock.unlock() }
            var hash = SHA256()
            let root = destination.projectRoot
            let ignored: Set<String> = [
                ".git", ".build", ".swiftpm", ".verdictui", "node_modules", ".venv", "logs",
                ".DS_Store",
            ]
            guard
                let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [])
            else { throw Failure("cannot inspect consumer sources") }
            var files: [URL] = []
            for case let file as URL in walker {
                if ignored.contains(file.lastPathComponent) {
                    walker.skipDescendants()
                    continue
                }
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    files.append(file)
                }
            }
            files.append(root.appendingPathComponent(".verdictui/config.json"))
            for file in files.sorted(by: { $0.path < $1.path }) {
                hash.update(data: Data(file.path.utf8))
                hash.update(data: try Data(contentsOf: file))
            }
            // Build products are excluded above; the configured executable's
            // metadata catches an external rebuild without hashing a huge binary.
            if includeExecutable {
                let attrs = try FileManager.default.attributesOfItem(
                    atPath: destination.executable.path)
                hash.update(
                    data: Data("\(attrs[.modificationDate] ?? ""):\(attrs[.size] ?? "")".utf8))
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }

        private func start() throws {
            var environment = ProcessInfo.processInfo.environment
            environment[ProjectRunner.delegationMarker] = destination.projectRoot.path
            environment.removeValue(forKey: "VERDICTUI_STOCK_DAEMON")
            var arguments: [String]
            var toChild: Pipe?
            var fromChild: Pipe?
            if wire == .mcp {
                toChild = Pipe()
                fromChild = Pipe()
                input = toChild!.fileHandleForWriting
                output = fromChild!.fileHandleForReading
                arguments = ["mcp"]
            } else {
                let path = "/tmp/vui-host-\(UUID().uuidString).sock"
                socketPath = path
                arguments = ["daemon", "start", "--socket", path]
            }
            let process = try OwnedCommandProcess.spawn(
                executable: destination.executable, arguments: arguments,
                directory: destination.projectRoot, environment: environment,
                standardInput: toChild?.fileHandleForReading.fileDescriptor,
                standardOutput: fromChild?.fileHandleForWriting.fileDescriptor,
                standardError: STDERR_FILENO)
            ownedChild = process
            try? toChild?.fileHandleForReading.close()
            try? fromChild?.fileHandleForWriting.close()
            if let path = socketPath {
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                while !DaemonTransport.isLive(path: path) {
                    guard try process.status() == nil, !shouldStop(),
                        ProcessInfo.processInfo.systemUptime < deadline
                    else {
                        throw Failure("consumer daemon did not become ready")
                    }
                    Thread.sleep(forTimeInterval: 0.025)
                }
            }
        }

        private func exchange(_ data: Data, expectsReply: Bool) throws -> Data? {
            guard let child, try child.status() == nil else {
                throw Failure("consumer host is not running")
            }
            let descriptor: Int32
            if wire == .daemon {
                guard let socketPath else { throw Failure("consumer socket absent") }
                descriptor = try connectSocket(socketPath)
            } else {
                guard let input else { throw Failure("consumer input absent") }
                descriptor = input.fileDescriptor
            }
            defer { if wire == .daemon { Darwin.close(descriptor) } }
            try writeAll(data + Data([10]), to: descriptor, shouldStop: shouldStop)
            guard expectsReply else { return nil }
            let reader = wire == .daemon ? descriptor : output!.fileDescriptor
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard !shouldStop() else { throw Failure("broker shutting down") }
                if let newline = pending.firstIndex(of: 10) {
                    let reply = Data(pending[...newline])
                    pending.removeSubrange(...newline)
                    guard
                        let result = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
                    else {
                        throw Failure("consumer response is not an object")
                    }
                    if wire == .mcp {
                        let request = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        guard String(describing: result["id"]) == String(describing: request?["id"])
                        else {
                            throw Failure("consumer response ID mismatch")
                        }
                    }
                    return reply
                }
                var fd = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
                guard poll(&fd, 1, 200) > 0 else { continue }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = read(reader, &bytes, bytes.count)
                guard count > 0 else {
                    throw Failure("consumer exited during request; outcome unavailable")
                }
                pending.append(contentsOf: bytes.prefix(count))
                guard pending.count <= 1_048_576 else {
                    throw Failure("consumer response exceeds limit")
                }
            }
            throw Failure("consumer request timed out; outcome unavailable")
        }

        func stop() {
            lock.lock()
            defer { lock.unlock() }
            try? input?.close()
            input = nil
            if let child { _ = try? child.stop(grace: 2) }
            try? output?.close()
            output = nil
            ownedChild = nil
            pending.removeAll()
            generation = nil
            if let path = socketPath { try? FileManager.default.removeItem(atPath: path) }
            socketPath = nil
        }

        private func failure(_ request: Data, reason: String) -> Data {
            let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
            let message = "consumer-unavailable: \(reason)"
            var result: [String: Any]
            if wire == .mcp {
                result = ["jsonrpc": "2.0", "id": object?["id"] ?? NSNull()]
                if object?["method"] as? String == "tools/call" {
                    result["result"] = [
                        "isError": true, "content": [["type": "text", "text": message]],
                    ]
                } else {
                    result["error"] = ["code": -32000, "message": message]
                }
            } else {
                result = ["ok": false, "id": object?["id"] ?? NSNull(), "error": message]
            }
            return (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))!
                + Data([10])
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private final class Shutdown: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        private var sources: [DispatchSourceSignal] = []
        var stopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
        init() {
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { [weak self] in
                    self?.lock.lock()
                    self?.flag = true
                    self?.lock.unlock()
                }
                source.resume()
                sources.append(source)
            }
            signal(SIGPIPE, SIG_IGN)
        }
        func close() { sources.forEach { $0.cancel() } }
    }

    private static func writeAll(_ data: Data, to fd: Int32, shouldStop: () -> Bool = { false })
        throws
    {
        let originalFlags = fcntl(fd, F_GETFL)
        guard originalFlags >= 0, fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw Failure("cannot configure broker output")
        }
        defer { _ = fcntl(fd, F_SETFL, originalFlags) }
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            guard !shouldStop(), ProcessInfo.processInfo.systemUptime < deadline else {
                throw Failure("broker output timed out or cancelled")
            }
            var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&ready, 1, 200) > 0 else { continue }
            let count = bytes.withUnsafeBytes {
                write(fd, $0.baseAddress!.advanced(by: offset), min(4096, bytes.count - offset))
            }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw Failure("consumer pipe/socket closed") }
            offset += count
        }
    }

    private static func connectSocket(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("cannot create consumer socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw Failure("consumer socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw Failure("consumer socket unavailable")
        }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
}
