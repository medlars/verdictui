import CryptoKit
import Darwin
import XCTest
import VerdictUIKernel
@testable import VerdictUIWeb

final class WebSessionIntegrationTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verdictui-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func node(_ tree: SemanticNode, id: String) throws -> SemanticNode {
        try XCTUnwrap(tree.flattened().first { $0.attributes["web.id"] == .string(id) }, "missing DOM id \(id)")
    }

    func testRealPageRendersJudgesAndTrustedClickChangesApplication() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = WebSessionManager(root: root, environment: [:])
        do {
            let info = try await manager.open(profile: "clean", url: fixture("clean"))
            XCTAssertGreaterThan(info.pid, 0)
            XCTAssertEqual(try WindowAudit.onScreenWindowCount(forPID: info.pid), 0)
            let before = try await manager.render(profile: "clean")
            let pass = try await manager.verify(profile: "clean", expectText: "Ready to verify")
            XCTAssertEqual(pass.status, .pass, "\(pass.findings)")
            let save = try node(before, id: "save")
            let after = try await manager.act(profile: "clean", action: .click(nodeID: save.structuralPath), expectText: "Task complete")
            XCTAssertEqual(after.status, .pass, "\(after.findings)")
            XCTAssertNotNil(after.delta)
            let brokenInfo = try await manager.open(profile: "clean", url: fixture("broken"))
            XCTAssertEqual(info.pid, brokenInfo.pid, "navigation must reuse the warm browser")
            let broken = try await manager.verify(profile: "clean")
            XCTAssertEqual(broken.status, .fail)
            XCTAssertTrue(broken.findings.contains { $0.rule == "tap-target" })
            try await manager.navigate(profile: "clean", url: fixture("empty"))
            let empty = try await manager.verify(profile: "clean")
            XCTAssertTrue(empty.findings.contains { $0.rule == "vacuous-verdict" })
            try await manager.close(profile: "clean")
            XCTAssertFalse(ProcessLiveness.isAlive(info.pid))
            XCTAssertFalse(FileManager.default.fileExists(atPath: ProfileRegistry(root: root).lockPath(for: "clean").path))
        } catch { await manager.closeAll(); throw error }
    }

    func testLoginTaskBadPasswordSecretRedactionAndProfilePersistence() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = UUID().uuidString + UUID().uuidString
        let badSecret = UUID().uuidString
        let hash = SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
        var url = URLComponents(url: try fixture("login"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "hash", value: hash)]
        let manager = WebSessionManager(root: root, environment: [
            "VERDICTUI_WEB_CRED_GOOD": secret, "VERDICTUI_WEB_CRED_BAD": badSecret])
        do {
            let info = try await manager.open(profile: "login", url: XCTUnwrap(url.url))
            XCTAssertFalse(info.url.contains(hash))
            let initial = try await manager.render(profile: "login")
            let password = try node(initial, id: "password")
            do {
                _ = try await manager.act(profile: "login", action: .type(nodeID: password.id, text: "not-a-reference"))
                XCTFail("password accepted literal typing")
            } catch let error as WebBrowserError {
                XCTAssertEqual(error, .invalidWebOperation(reason: "password fields require a credential reference"))
            }
            let wrongEntry = try await manager.act(profile: "login", action: .credential(nodeID: password.id, reference: "bad"))
            let wrong = try await manager.act(profile: "login", action: .submit(nodeID: password.id), expectText: "Welcome")
            XCTAssertEqual(wrong.status, .fail)
            XCTAssertTrue(wrong.findings.contains { $0.rule == "web-expectation" && !$0.nodeID.isEmpty })
            let currentPassword = try node(XCTUnwrap(wrong.tree), id: "password")
            let entry = try await manager.act(profile: "login", action: .credential(nodeID: currentPassword.id, reference: "good"))
            let login = try await manager.act(profile: "login", action: .submit(nodeID: currentPassword.id), expectText: "Welcome")
            XCTAssertEqual(login.status, .pass, "\(login.findings)")
            let finish = try node(XCTUnwrap(login.tree), id: "finish")
            let task = try await manager.act(profile: "login", action: .click(nodeID: finish.id), expectText: "Task complete")
            XCTAssertEqual(task.status, .pass, "\(task.findings)")
            let encoded = String(decoding: try JSONEncoder().encode([wrongEntry, wrong, entry, login, task]), as: UTF8.self)
            XCTAssertFalse(encoded.contains(secret)); XCTAssertFalse(encoded.contains(badSecret))
            let process = Process(); let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-p", String(info.pid), "-o", "command="]
            process.standardOutput = output
            try process.run()
            let argv = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(argv.contains("--headless=new"))
            XCTAssertFalse(argv.contains(secret)); XCTAssertFalse(argv.contains(badSecret))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("login/launch-stderr.log").path))
            try await manager.close(profile: "login")
            _ = try await manager.open(profile: "login", url: XCTUnwrap(url.url))
            let persisted = try await manager.verify(profile: "login", expectText: "Task complete")
            XCTAssertEqual(persisted.status, .pass)
            await manager.closeAll()
        } catch { await manager.closeAll(); throw error }
    }

    func testConcurrentProfilesAreIsolatedAndSameProfileRefusesAttach() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = WebSessionManager(root: root, environment: [:])
        let second = WebSessionManager(root: root, environment: [:])
        do {
            let url = try fixture("clean")
            async let a = first.open(profile: "a", url: url)
            async let b = second.open(profile: "b", url: url)
            let (one, two) = try await (a, b)
            XCTAssertNotEqual(one.pid, two.pid)
            XCTAssertEqual(try WindowAudit.onScreenWindowCount(forPID: one.pid), 0)
            XCTAssertEqual(try WindowAudit.onScreenWindowCount(forPID: two.pid), 0)
            do { _ = try await second.open(profile: "a", url: url); XCTFail("cross-attached to profile") }
            catch let error as WebBrowserError {
                guard case .profileInUse = error else { return XCTFail("wrong error: \(error)") }
            }
            let tree = try await first.render(profile: "a")
            _ = try await first.act(profile: "a", action: .click(nodeID: node(tree, id: "save").id))
            let untouched = try await second.verify(profile: "b", expectText: "Ready to verify")
            XCTAssertEqual(untouched.status, .pass)
            await first.closeAll(); await second.closeAll()
        } catch { await first.closeAll(); await second.closeAll(); throw error }
    }

    func testBrowserDownIsUnavailableAndReleasesProfile() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = WebSessionManager(root: root, environment: [:])
        do {
            let info = try await manager.open(profile: "dead", url: fixture("clean"))
            kill(info.pid, SIGKILL)
            _ = await HeadlessBrowser.awaitDeath(pid: info.pid, within: 5)
            do { _ = try await manager.verify(profile: "dead"); XCTFail("dead browser produced verdict") }
            catch { XCTAssertTrue(error is WebBrowserError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: ProfileRegistry(root: root).lockPath(for: "dead").path))
            await manager.closeAll()
        } catch { await manager.closeAll(); throw error }
        let missing = WebSessionManager(root: root, environment: ["VERDICTUI_WEB_BROWSER": "/nonexistent"])
        do { _ = try await missing.open(profile: "missing", url: fixture("clean")); XCTFail("missing browser opened") }
        catch { XCTAssertEqual(error as? WebBrowserError, .overrideNotExecutable(path: "/nonexistent")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProfileRegistry(root: root).lockPath(for: "missing").path))
    }

    func testInvalidNavigationAndUnknownIdentityFailClosed() async throws {
        let manager = WebSessionManager(environment: [:])
        do { _ = try await manager.open(profile: "invalid", url: XCTUnwrap(URL(string: "javascript:alert(1)"))); XCTFail("unsafe URL") }
        catch { XCTAssertTrue(error is WebBrowserError) }
        do { _ = try await manager.render(profile: "missing"); XCTFail("missing identity rendered") }
        catch { XCTAssertEqual(error as? WebBrowserError, .unknownSession(profile: "missing")) }
    }
}
