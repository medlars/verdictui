import Foundation
import VerdictUIWeb

typealias OwnedCommandProcess = VerdictUIWeb.OwnedCommandProcess

/// A subprocess boundary for project checks: no shell, bounded time and output.
enum BoundedCommand {
    struct Result: Sendable { let code: Int32; let output: Data }
    enum Failure: Error { case timeout, excessiveOutput, temporaryFile, invalidLimits }

    static func run(executable: URL, arguments: [String], root: URL,
                    timeout: TimeInterval = 330, limit: Int = 8 * 1_024 * 1_024) async throws -> Result {
        guard timeout.isFinite, timeout > 0, limit > 0 else { throw Failure.invalidLimits }
        let worker = Task.detached {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600]) else {
                throw Failure.temporaryFile
            }
            defer { try? FileManager.default.removeItem(at: file) }
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: ProjectRunner.delegationMarker)
            let process = try OwnedCommandProcess.spawn(executable: executable, arguments: arguments,
                directory: root, environment: environment, standardOutput: output.fileDescriptor)
            let deadline = ContinuousClock.now + .seconds(timeout)
            do {
                while try process.status() == nil {
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    if size > limit { throw Failure.excessiveOutput }
                    if ContinuousClock.now >= deadline { throw Failure.timeout }
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(20))
                }
                let code = try process.stop(grace: 0)
                try Task.checkCancellation()
                let data = try Data(contentsOf: file)
                guard data.count <= limit else { throw Failure.excessiveOutput }
                return Result(code: code, output: data)
            } catch {
                try process.stop()
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
