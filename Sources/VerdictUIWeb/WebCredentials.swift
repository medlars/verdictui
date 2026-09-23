import Darwin
import Foundation

/// A reference resolver, never a command-line password channel. 1Password reads
/// receive only an op:// reference in argv; fallback values come from the shared
/// environment. Child output is kept in memory and never included in an error.
public actor WebCredentials {
    private struct Operation {
        let process: OwnedCommandProcess
        let worker: Task<String, Error>
    }
    private var operations: [UUID: Operation] = [:]
    private var closed = false
    let environment: [String: String]
    let sharedFile: URL
    let onePassword: URL?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                sharedFile: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Projects/.env.shared"),
                onePassword: URL? = WebCredentials.installedOnePassword()) {
        self.environment = environment
        self.sharedFile = sharedFile
        if let override = environment["VERDICTUI_WEB_OP"] {
            self.onePassword = override.isEmpty ? nil : URL(fileURLWithPath: override)
        } else { self.onePassword = onePassword }
    }

    public static func installedOnePassword() -> URL? {
        ["/opt/homebrew/bin/op", "/usr/local/bin/op"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    /// Cancels and awaits every resolver before the browser profile is released.
    public func close() async throws {
        closed = true
        let pending = operations
        pending.values.forEach { $0.worker.cancel() }
        var failed = false
        for (id, operation) in pending {
            do {
                _ = try await Task.detached { try operation.process.stop() }.value
                _ = await operation.worker.result
                operations.removeValue(forKey: id)
            } catch { failed = true }
        }
        if failed { throw WebBrowserError.credentialUnavailable }
    }

    public func resolve(_ reference: String) async throws -> String {
        guard !closed, !Task.isCancelled else { throw WebBrowserError.credentialUnavailable }
        let direct = reference.hasPrefix("op://")
        guard direct || (!reference.isEmpty && reference.count <= 100
            && reference.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })) else {
            throw WebBrowserError.credentialUnavailable
        }
        let key = "VERDICTUI_WEB_CRED_" + reference.uppercased()
        let configured = direct ? reference : environment[key] ?? sharedValue(key)
        let opReference = configured?.hasPrefix("op://") == true ? configured : nil
        if let opReference {
            guard let onePassword else { throw WebBrowserError.credentialUnavailable }
            return try await runOnePassword(["read", opReference, "--no-newline"], executable: onePassword)
        }
        // Named references select a 1Password item first. The shared secret is
        // a fallback when that item cannot be resolved, never command text.
        if let onePassword {
            do {
                return try await runOnePassword(["item", "get", reference, "--fields", "label=password", "--reveal"], executable: onePassword)
            } catch {
                if closed || Task.isCancelled { throw WebBrowserError.credentialUnavailable }
            }
        }
        guard !direct, let configured, !configured.isEmpty, opReference == nil else {
            throw WebBrowserError.credentialUnavailable
        }
        return configured
    }

    private func sharedValue(_ key: String) -> String? {
        guard let data = try? Data(contentsOf: sharedFile), data.count <= 4_000_000,
            let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            var clean = line.trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("export ") { clean.removeFirst(7) }
            guard let equals = clean.firstIndex(of: "="), clean[..<equals].trimmingCharacters(in: .whitespaces) == key else { continue }
            var value = String(clean[clean.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, (first == "\"" || first == "'"), value.last == first {
                value.removeFirst(); value.removeLast()
            }
            return value
        }
        return nil
    }

    private func runOnePassword(_ arguments: [String], executable: URL) async throws -> String {
        guard !closed, !Task.isCancelled else { throw WebBrowserError.credentialUnavailable }
        let pipe = Pipe()
        let process: OwnedCommandProcess
        do {
            process = try OwnedCommandProcess.spawn(executable: executable, arguments: arguments,
                directory: FileManager.default.temporaryDirectory, environment: environment,
                standardOutput: pipe.fileHandleForWriting.fileDescriptor)
        } catch {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            throw WebBrowserError.credentialUnavailable
        }
        // Only the owned child retains the writer. EOF is now tied to group
        // cleanup, including any helper that inherited stdout from the CLI.
        try? pipe.fileHandleForWriting.close()
        let reader = Task.detached {
            defer { try? pipe.fileHandleForReading.close() }
            var output = Data()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                guard output.count + chunk.count <= 65_536 else { throw WebBrowserError.credentialUnavailable }
                output.append(chunk)
            }
            return output
        }
        let worker = Task.detached {
            do {
                let deadline = ContinuousClock.now + .seconds(15)
                while try process.status() == nil {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw WebBrowserError.credentialUnavailable }
                    _ = process.waitForExitEvent(timeout: 0.025)
                }
                let code = try process.stop(grace: 0)
                let data = try await reader.value
                try Task.checkCancellation()
                guard code == 0, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                    throw WebBrowserError.credentialUnavailable
                }
                return value.hasSuffix("\n") ? String(value.dropLast()) : value
            } catch {
                try process.stop()
                _ = await reader.result
                throw WebBrowserError.credentialUnavailable
            }
        }
        let id = UUID()
        operations[id] = Operation(process: process, worker: worker)
        do {
            let value = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            operations.removeValue(forKey: id)
            guard !closed, !Task.isCancelled else { throw WebBrowserError.credentialUnavailable }
            return value
        } catch {
            if (try? process.status()) != nil { operations.removeValue(forKey: id) }
            throw WebBrowserError.credentialUnavailable
        }
    }
}
