import Foundation
import VerdictUIWeb

typealias OwnedCommandProcess = VerdictUIWeb.OwnedCommandProcess
typealias GuardedProcess = VerdictUIWeb.GuardedProcess

/// A subprocess boundary for project checks: no shell, bounded time and output.
enum BoundedCommand {
    struct Result: Sendable { let code: Int32; let output: Data; let error: Data }
    enum Failure: Error { case timeout, excessiveOutput, temporaryFile, invalidLimits }

    private static func validateOutputSize(_ output: Int, error: Int, limit: Int) throws {
        guard output <= limit, error <= limit - output else { throw Failure.excessiveOutput }
    }

    static func run(executable: URL, arguments: [String], root: URL,
                    timeout: TimeInterval = 330, limit: Int = 8 * 1_024 * 1_024,
                    captureStandardError: Bool = false) async throws -> Result {
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
            let errorFile = file.appendingPathExtension("stderr")
            var errorOutput: FileHandle?
            defer {
                try? errorOutput?.close()
                if captureStandardError { try? FileManager.default.removeItem(at: errorFile) }
            }
            if captureStandardError {
                guard FileManager.default.createFile(atPath: errorFile.path, contents: nil,
                                                    attributes: [.posixPermissions: 0o600]) else {
                    throw Failure.temporaryFile
                }
                errorOutput = try FileHandle(forWritingTo: errorFile)
            }
            func validateSize() throws {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let errorSize = captureStandardError
                    ? try errorFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 : 0
                try validateOutputSize(size, error: errorSize, limit: limit)
            }
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: ProjectRunner.delegationMarker)
            let process = try GuardedProcess.spawn(executable: executable, arguments: arguments,
                directory: root, environment: environment, standardOutput: output.fileDescriptor,
                standardError: errorOutput?.fileDescriptor)
            let deadline = ContinuousClock.now + .seconds(timeout)
            do {
                while try process.status() == nil {
                    try validateSize()
                    if ContinuousClock.now >= deadline { throw Failure.timeout }
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(20))
                }
                let code = try process.stop(grace: 0)
                try Task.checkCancellation()
                // All owned writers have exited before inspecting or reading
                // either stream; diagnostics cannot deadlock a stdout reader.
                try validateSize()
                let data = try Data(contentsOf: file)
                let errorData = captureStandardError ? try Data(contentsOf: errorFile) : Data()
                try validateOutputSize(data.count, error: errorData.count, limit: limit)
                return Result(code: code, output: data, error: errorData)
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
