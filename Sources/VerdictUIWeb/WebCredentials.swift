import Darwin
import Foundation

/// A reference resolver, never a command-line password channel. 1Password reads
/// receive only an op:// reference in argv; fallback values come from the shared
/// environment. Child output is kept in memory and never included in an error.
public struct WebCredentials: Sendable {
    let environment: [String: String]
    let sharedFile: URL
    let onePassword: URL?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                sharedFile: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Projects/.env.shared"),
                onePassword: URL? = nil) {
        self.environment = environment
        self.sharedFile = sharedFile
        self.onePassword = onePassword ?? ["/opt/homebrew/bin/op", "/usr/local/bin/op"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    public func resolve(_ reference: String) async throws -> String {
        let direct = reference.hasPrefix("op://")
        guard direct || (!reference.isEmpty && reference.count <= 100
            && reference.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })) else {
            throw WebBrowserError.credentialUnavailable
        }
        let key = "VERDICTUI_WEB_CRED_" + reference.uppercased()
        let configured = direct ? reference : environment[key] ?? sharedValue(key)
        let opReference = configured?.hasPrefix("op://") == true ? configured : nil
        if let opReference, let onePassword {
            return try await readOnePassword(opReference, executable: onePassword)
        }
        // Never pass a credential name to `op item get`: names can resolve
        // ambiguously. A configured op:// reference selects the exact field.
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

    private func readOnePassword(_ reference: String, executable: URL) async throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["read", reference, "--no-newline"]
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw WebBrowserError.credentialUnavailable }
        // op outputs small credential fields. Read concurrently so a larger
        // field cannot fill a pipe and stall the deadline loop.
        let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        do {
            let deadline = ContinuousClock.now + .seconds(15)
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw WebBrowserError.credentialUnavailable }
                try await Task.sleep(for: .milliseconds(25))
            }
            let data = await reader.value
            guard process.terminationStatus == 0, data.count <= 65_536,
                let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                throw WebBrowserError.credentialUnavailable
            }
            return value
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = await reader.value
            throw WebBrowserError.credentialUnavailable
        }
    }
}
