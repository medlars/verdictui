import Foundation
import XCTest
import VerdictUIProbe
@testable import VerdictUICLICore

final class DaemonClientTests: XCTestCase {
    func testInvalidSocketPathIsUnavailable() async {
        for path in [String(repeating: "x", count: 200), "a\0b", "/tmp/verdictui-absent-\(UUID())"] {
            do {
                _ = try await DaemonClient.send(DaemonRequest(method: "ping"), socketPath: path)
                XCTFail("invalid or missing socket must fail")
            } catch {
                XCTAssertTrue(String(describing: error).contains("unavailable"))
            }
        }
    }

    @MainActor
    func testRealClientRoundTripAndSocketRemovalStopsDaemon() async throws {
        let path = "/tmp/vui-client-\(UUID().uuidString).sock"
        let engine = VerdictEngine(registry: ScenarioRegistry([]), baselines: .standard(root: URL(fileURLWithPath: NSTemporaryDirectory())))
        let transport = DaemonTransport(engine: engine, socketPath: path)
        let server = Task { try await transport.serve() }
        defer { server.cancel(); try? FileManager.default.removeItem(atPath: path) }
        for _ in 0..<100 {
            if DaemonTransport.isLive(path: path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(DaemonTransport.isLive(path: path))
        let response = try await DaemonClient.send(DaemonRequest(method: "ping", id: "client"), socketPath: path)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, "client")
        try FileManager.default.removeItem(atPath: path)
        try await server.value
        XCTAssertFalse(DaemonTransport.isLive(path: path))
    }
}
