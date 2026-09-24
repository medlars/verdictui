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

    private func persistedTaskState(root: URL, profile: String = "login") async throws -> [String: CDPValue] {
        let endpoint = try XCTUnwrap(DevtoolsEndpoint.read(in: root.appendingPathComponent(profile)))
        let transport = try CDPTransport(endpoint: endpoint)
        do {
            let result = try await transport.send(method: "Target.getTargets")
            guard case let .array(targets) = result["targetInfos"],
                  let page = targets.compactMap({ value -> [String: CDPValue]? in
                      if case let .object(row) = value, row["type"] == .string("page") { return row }
                      return nil
                  }).first, let targetID = page["targetId"]?.stringValue else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let attached = try await transport.send(method: "Target.attachToTarget", params: [
                "targetId": .string(targetID), "flatten": .bool(true)])
            let session = try XCTUnwrap(attached["sessionId"]?.stringValue)
            // Fixed read-only expression: never disclose credentials or query values.
            let state = try await transport.send(method: "Runtime.evaluate", params: [
                "expression": .string("({stored:localStorage.getItem('task-complete')==='yes',status:document.getElementById('status').textContent,protocol:location.protocol,origin:location.origin})"),
                "returnByValue": .bool(true)], sessionID: session)
            await transport.close()
            guard case let .object(remote) = state["result"], case let .object(value) = remote["value"], state["exceptionDetails"] == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return value
        } catch { await transport.close(); throw error }
    }

    /// Metadata only: retain shutdown/profile evidence without emitting stored values.
    private func profileDiskState(root: URL) -> [String: CDPValue] {
        let profile = root.appendingPathComponent("login/Default")
        let preferences = profile.appendingPathComponent("Preferences")
        var result: [String: CDPValue] = [:]
        do {
            if FileManager.default.fileExists(atPath: preferences.path) {
                let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: preferences)) as? [String: Any]
                let state = parsed?["profile"] as? [String: Any]
                if let exitType = state?["exit_type"] as? String { result["exitType"] = .string(exitType) }
                if let exitedCleanly = state?["exited_cleanly"] as? Bool { result["exitedCleanly"] = .bool(exitedCleanly) }
            }
            let database = profile.appendingPathComponent("Local Storage/leveldb")
            if FileManager.default.fileExists(atPath: database.path) {
                var sizes: [String: CDPValue] = [:]
                for name in try FileManager.default.contentsOfDirectory(atPath: database.path) {
                    let attributes = try FileManager.default.attributesOfItem(atPath: database.appendingPathComponent(name).path)
                    if let size = attributes[.size] as? NSNumber { sizes[name] = .number(size.doubleValue) }
                }
                result["localStorageFileSizes"] = .object(sizes)
            }
        } catch {
            let failure = error as NSError
            result["metadataUnavailable"] = .string("\(failure.domain):\(failure.code)")
        }
        return result
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
            for expectation in ["", "   ", String(repeating: "x", count: 4097)] {
                do { _ = try await manager.act(profile: "clean", action: .click(nodeID: save.id), expectText: expectation)
                    XCTFail("invalid assertion accepted")
                } catch { XCTAssertTrue(error is WebBrowserError) }
            }
            let after = try await manager.act(profile: "clean", action: .click(nodeID: save.structuralPath), expectText: "Task complete")
            XCTAssertEqual(after.status, .pass, "\(after.findings)")
            XCTAssertNotNil(after.delta)
            let name = try node(before, id: "name")
            let unasserted = try await manager.act(profile: "clean", action: .type(nodeID: name.id, text: "example"))
            XCTAssertTrue(unasserted.findings.contains { $0.rule == "web-outcome-unasserted" && $0.severity == .warning })
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
        let server = try await LocalHTTPFixture.start(root: root)
        let secret = UUID().uuidString + UUID().uuidString
        let badSecret = UUID().uuidString
        let hash = SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
        var url = URLComponents(url: server.origin.appendingPathComponent("login.html"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "hash", value: hash)]
        let manager = WebSessionManager(root: root, environment: [
            "VERDICTUI_WEB_CRED_GOOD": secret, "VERDICTUI_WEB_CRED_BAD": badSecret, "VERDICTUI_WEB_OP": ""])
        do {
            let info = try await manager.open(profile: "login", url: XCTUnwrap(url.url))
            XCTAssertFalse(info.url.contains(hash))
            let fresh = try await persistedTaskState(root: root)
            XCTAssertEqual(fresh["protocol"], .string("http:"))
            XCTAssertEqual(fresh["origin"], .string(server.origin.absoluteString))
            XCTAssertEqual(fresh["stored"], .bool(false), "a fresh profile must begin without a saved task")
            let initial = try await manager.render(profile: "login")
            let password = try node(initial, id: "password")
            XCTAssertEqual(password.text, "Password")
            XCTAssertEqual(try node(initial, id: "username").text, "Username")
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
            let storedBefore = try await persistedTaskState(root: root)
            XCTAssertEqual(storedBefore["stored"], .bool(true), "visible success must include actual storage write")
            XCTAssertEqual(storedBefore["protocol"], .string("http:"))
            XCTAssertEqual(storedBefore["origin"], .string(server.origin.absoluteString))
            let closeStart = ContinuousClock.now
            try await manager.close(profile: "login")
            let closeElapsed = closeStart.duration(to: .now)
            let diskAfterClose = profileDiskState(root: root)
            _ = try await manager.open(profile: "login", url: XCTUnwrap(url.url))
            let storedAfter = try await persistedTaskState(root: root)
            let persisted = try await manager.verify(profile: "login", expectText: "Task complete")
            let persistedEvidence = String(decoding: try JSONEncoder().encode(persisted), as: UTF8.self)
            XCTAssertFalse(persistedEvidence.contains(secret)); XCTAssertFalse(persistedEvidence.contains(badSecret))
            let diagnostic: [String: CDPValue] = ["before": .object(storedBefore), "after": .object(storedAfter),
                "closeDuration": .string(String(describing: closeElapsed)), "diskAfterClose": .object(diskAfterClose)]
            print("PROFILE-PERSISTENCE " + String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self))
            XCTAssertEqual(storedAfter["origin"], storedBefore["origin"], "reopen must retain the same storage origin")
            XCTAssertEqual(storedAfter["protocol"], .string("http:"))
            XCTAssertEqual(storedAfter["stored"], .bool(true), "storage must survive normal close/reopen")
            XCTAssertEqual(persisted.status, .pass, persistedEvidence)
            try await manager.close(profile: "login")
            _ = try await manager.open(profile: "isolated", url: XCTUnwrap(url.url))
            let isolated = try await persistedTaskState(root: root, profile: "isolated")
            XCTAssertEqual(isolated["origin"], storedBefore["origin"])
            XCTAssertEqual(isolated["protocol"], .string("http:"))
            XCTAssertEqual(isolated["stored"], .bool(false), "another profile must not inherit the saved task")
            let untouched = try await manager.verify(profile: "isolated", expectText: "Sign in to continue")
            XCTAssertEqual(untouched.status, .pass, "\(untouched.findings)")
            try await manager.close(profile: "isolated")
            try server.stop()
            try FileManager.default.removeItem(at: root)
        } catch {
            let original = error
            let failures = await manager.closeAll()
            for failure in failures { XCTFail("browser cleanup failed: \(failure)") }
            do { try server.stop() }
            catch { XCTFail("HTTP fixture cleanup failed: \(error)") }
            throw original
        }
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
            catch { XCTAssertEqual(error as? WebBrowserError, .unknownSession(profile: "dead")) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: ProfileRegistry(root: root).lockPath(for: "dead").path))
            let sessionsAfterFailure = await manager.list()
            XCTAssertTrue(sessionsAfterFailure.isEmpty, "dead identity must not remain discoverable")
            let reopened = try await manager.open(profile: "dead", url: fixture("clean"))
            XCTAssertTrue(ProcessLiveness.isAlive(reopened.pid))
            let recovered = try await manager.verify(profile: "dead", expectText: "Ready to verify")
            XCTAssertEqual(recovered.status, .pass)
            // list itself must detect a crash even without a preceding action.
            kill(reopened.pid, SIGKILL)
            _ = await HeadlessBrowser.awaitDeath(pid: reopened.pid, within: 5)
            let sessionsAfterIdleCrash = await manager.list()
            XCTAssertTrue(sessionsAfterIdleCrash.isEmpty)
            let third = try await manager.open(profile: "dead", url: fixture("clean"))
            kill(third.pid, SIGKILL)
            _ = await HeadlessBrowser.awaitDeath(pid: third.pid, within: 5)
            // open must evict a dead identity without requiring list/close.
            let fourth = try await manager.open(profile: "dead", url: fixture("clean"))
            XCTAssertTrue(ProcessLiveness.isAlive(fourth.pid))
            await manager.closeAll()
        } catch { await manager.closeAll(); throw error }
        let missing = WebSessionManager(root: root, environment: ["VERDICTUI_WEB_BROWSER": "/nonexistent"])
        do { _ = try await missing.open(profile: "missing", url: fixture("clean")); XCTFail("missing browser opened") }
        catch { XCTAssertEqual(error as? WebBrowserError, .overrideNotExecutable(path: "/nonexistent")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProfileRegistry(root: root).lockPath(for: "missing").path))
    }

    func testRealControlLabelsAreDiscoverableWithoutExposingExistingValues() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = WebSessionManager(root: root, environment: [:])
        do {
            _ = try await manager.open(profile: "names", url: fixture("names"))
            let tree = try await manager.render(profile: "names")
            for (id, expected) in [("explicit", "Account name"), ("wrapped", "Wrapped username"),
                ("referenced", "Accessible reference"), ("placeholder", "Search catalogue"), ("notes", "Private notes")] {
                let field = try node(tree, id: id)
                XCTAssertEqual(field.role, .textField)
                XCTAssertEqual(field.text, expected)
                XCTAssertFalse(field.id.isEmpty)
                XCTAssertTrue(field.children.isEmpty)
            }
            let encoded = String(decoding: try JSONEncoder().encode(tree), as: UTF8.self)
            XCTAssertFalse(encoded.contains("existing-private-input-value"))
            XCTAssertFalse(encoded.contains("existing-private-textarea-value"))
            await manager.closeAll()
        } catch { await manager.closeAll(); throw error }
    }

    func testInvalidNavigationAndUnknownIdentityFailClosed() async throws {
        let manager = WebSessionManager(environment: [:])
        do { _ = try await manager.open(profile: "invalid", url: XCTUnwrap(URL(string: "javascript:alert(1)"))); XCTFail("unsafe URL") }
        catch { XCTAssertTrue(error is WebBrowserError) }
        do { _ = try await manager.render(profile: "missing"); XCTFail("missing identity rendered") }
        catch { XCTAssertEqual(error as? WebBrowserError, .unknownSession(profile: "missing")) }
    }
}
