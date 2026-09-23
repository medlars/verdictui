import Darwin
import Foundation

/// A subprocess boundary for project checks: no shell, bounded time and output.
enum BoundedCommand {
    struct Result: Sendable { let code: Int32; let output: Data }
    enum Failure: Error { case timeout, excessiveOutput, temporaryFile }

    static func run(executable: URL, arguments: [String], root: URL,
                    timeout: TimeInterval = 330, limit: Int = 8 * 1_024 * 1_024) async throws -> Result {
        let worker = Task.detached {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600]) else {
                throw Failure.temporaryFile
            }
            defer { try? FileManager.default.removeItem(at: file) }
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = root
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: ProjectRunner.delegationMarker)
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = ContinuousClock.now + .seconds(timeout)
            defer {
                if process.isRunning {
                    process.terminate()
                    let stop = ContinuousClock.now + .seconds(1)
                    while process.isRunning && ContinuousClock.now < stop { usleep(20_000) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            while process.isRunning {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                if size > limit || ContinuousClock.now >= deadline || Task.isCancelled {
                    if size > limit { throw Failure.excessiveOutput }
                    throw Failure.timeout
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let data = try Data(contentsOf: file)
            guard data.count <= limit else { throw Failure.excessiveOutput }
            return Result(code: process.terminationStatus, output: data)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
