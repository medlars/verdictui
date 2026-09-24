import Foundation
import XCTest
@testable import VerdictUIWeb

/// One launch-owned loopback origin, retained across browser close/reopen.
struct LocalHTTPFixture {
    private let process: GuardedProcess
    let origin: URL

    static func start(root: URL) async throws -> LocalHTTPFixture {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures"))
        let portFile = root.appendingPathComponent("server.port")
        let process = try GuardedProcess.spawn(executable: fixturePython(),
            arguments: [fixture.path, fixture.deletingLastPathComponent().path, portFile.path],
            directory: root, environment: ProcessInfo.processInfo.environment)
        do {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                guard try process.status() == nil else { throw CocoaError(.executableRuntimeMismatch) }
                if let text = try? String(contentsOf: portFile, encoding: .utf8), let port = Int(text) {
                    let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
                    return LocalHTTPFixture(process: process, origin: origin)
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw WebBrowserError.invalidWebOperation(reason: "loopback fixture did not publish its port within 5 seconds")
        } catch {
            try process.stop()
            throw error
        }
    }

    func stop() throws { _ = try process.stop() }

    private static func fixturePython() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["VERDICTUI_TEST_PYTHON"] {
            guard configured.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: configured) else {
                throw WebBrowserError.invalidWebOperation(reason: "configured fixture Python is not executable")
            }
            return URL(fileURLWithPath: configured)
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("python3.14")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw WebBrowserError.invalidWebOperation(reason: "fixture requires VERDICTUI_TEST_PYTHON or python3.14 on PATH")
    }
}
