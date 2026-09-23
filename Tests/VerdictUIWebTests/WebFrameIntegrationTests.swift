import Darwin
import Foundation
import XCTest
import VerdictUIKernel
@testable import VerdictUIWeb

final class WebFrameIntegrationTests: XCTestCase {
    private func server(root: URL) async throws -> (Process, Int) {
        let python = try XCTUnwrap(["/opt/homebrew/bin/python3.14", "/usr/local/bin/python3.14", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) })
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures"))
        let portFile = root.appendingPathComponent("server.port")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [fixture.path, fixture.deletingLastPathComponent().path, portFile.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), let port = Int(text) { return (process, port) }
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        throw WebBrowserError.invalidWebOperation(reason: "loopback fixture server failed to start")
    }

    func testSameAndCrossOriginFramesRenderAndActWithCorrectRootCoordinates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vui-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, port) = try await server(root: root)
        defer { if server.isRunning { kill(server.processIdentifier, SIGKILL); server.waitUntilExit() } }
        let manager = WebSessionManager(root: root.appendingPathComponent("profiles"), environment: [:])
        do {
            for route in ["same", "cross"] {
                let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(route)"))
                _ = try await manager.open(profile: "frames", url: url)
                let tree = try await manager.render(profile: "frames")
                let owner = try XCTUnwrap(tree.flattened().first { $0.attributes["web.id"] == .string("child") })
                let button = try XCTUnwrap(tree.flattened().first { $0.attributes["web.id"] == .string("save") })
                XCTAssertEqual(button.frame.x, owner.frame.x + 3 + 24, accuracy: 0.5)
                XCTAssertEqual(button.frame.y, owner.frame.y + 3 + 66, accuracy: 0.5)
                XCTAssertNotEqual(button.attributes["web.frame"], owner.attributes["web.frame"])
                let textField = try XCTUnwrap(tree.flattened().first { $0.attributes["web.id"] == .string("name") })
                let typed = try await manager.act(profile: "frames", action: .type(nodeID: textField.id, text: "frame text"))
                XCTAssertFalse(String(decoding: try JSONEncoder().encode(typed), as: UTF8.self).contains("frame text"))
                let report = try await manager.act(profile: "frames", action: .click(nodeID: button.id), expectText: "Task complete")
                XCTAssertEqual(report.status, .pass, "\(route): \(report.findings)")
            }
            _ = try await manager.open(profile: "frames", url: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/network")))
            let completed = try await manager.verify(profile: "frames", expectText: "Network task complete")
            XCTAssertEqual(completed.status, .pass)
            await manager.closeAll()
        } catch { await manager.closeAll(); throw error }
    }
}
