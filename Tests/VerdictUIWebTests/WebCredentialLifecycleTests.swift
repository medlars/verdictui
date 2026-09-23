import Darwin
import XCTest
import VerdictUIKernel
@testable import VerdictUIWeb

@MainActor
final class WebCredentialLifecycleTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verdictui-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("op")
        let script = "#!/bin/sh\ntrap '' TERM\necho $$ > \"$RESOLVER_ROOT/leader.pid\"\n/bin/sleep 60 &\necho $! > \"$RESOLVER_ROOT/child.pid\"\nwait\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable)
    }

    private func pid(_ name: String, root: URL) async throws -> pid_t {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: root.appendingPathComponent(name + ".pid"), encoding: .utf8),
               let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 1 { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func assertGone(_ pids: [pid_t]) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while pids.contains(where: { kill($0, 0) == 0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        for value in pids { XCTAssertNotEqual(kill(value, 0), 0, "owned resolver process \(value) survived cleanup") }
    }

    func testCloseAndCancellationAwaitOwnedResolverGroupAndRefuseFallback() async throws {
        for cancel in [false, true] {
            let (root, executable) = try fixture()
            let resolver = WebCredentials(environment: ["RESOLVER_ROOT": root.path,
                "VERDICTUI_WEB_CRED_TEST": UUID().uuidString], onePassword: executable)
            let operation = Task { try await resolver.resolve("test") }
            let leader = try await pid("leader", root: root)
            let child = try await pid("child", root: root)
            defer { for value in [child, leader] where getpgid(value) == leader { kill(value, SIGKILL) } }
            XCTAssertEqual(getpgid(child), leader)
            let cancellationStart = ContinuousClock.now
            if cancel { operation.cancel() } else { try await resolver.close() }
            do { _ = try await operation.value; XCTFail("cancelled/closed resolver returned a fallback credential") }
            catch { XCTAssertEqual(error as? WebBrowserError, .credentialUnavailable) }
            XCTAssertLessThan(cancellationStart.duration(to: .now), .seconds(3), "cancellation must interrupt the resolver deadline")
            try await assertGone([leader, child])
            try await resolver.close()
            do { _ = try await resolver.resolve("test"); XCTFail("closed resolver launched again") }
            catch { XCTAssertEqual(error as? WebBrowserError, .credentialUnavailable) }
        }
    }

    func testSessionCloseAwaitsCredentialLookupAndReleasesProfile() async throws {
        let (root, executable) = try fixture()
        let profiles = root.appendingPathComponent("profiles")
        let manager = WebSessionManager(root: profiles, environment: ["RESOLVER_ROOT": root.path,
            "VERDICTUI_WEB_OP": executable.path])
        let page = try XCTUnwrap(Bundle.module.url(forResource: "login", withExtension: "html", subdirectory: "Fixtures"))
        do {
            let info = try await manager.open(profile: "owned", url: page)
            let tree = try await manager.render(profile: "owned")
            let password = try XCTUnwrap(tree.flattened().first { $0.text == "Password" })
            let operation = Task { try await manager.act(profile: "owned", action: .credential(nodeID: password.id, reference: "test")) }
            let leader = try await pid("leader", root: root)
            let child = try await pid("child", root: root)
            defer { for value in [child, leader] where getpgid(value) == leader { kill(value, SIGKILL) } }
            let firstClose = Task { try await manager.close(profile: "owned") }
            try await Task.sleep(for: .milliseconds(50))
            try await manager.close(profile: "owned")
            XCTAssertNotEqual(kill(leader, 0), 0, "a concurrent close returned before its owned resolver stopped")
            try await firstClose.value
            do { _ = try await operation.value; XCTFail("credential action succeeded after session close") }
            catch { XCTAssertTrue(error is WebBrowserError) }
            try await assertGone([leader, child, info.pid])
            let reopened = try await manager.open(profile: "owned", url: page)
            XCTAssertNotEqual(info.pid, reopened.pid)
            await manager.closeAll()
        } catch { await manager.closeAll(); throw error }
    }

    func testClosedResolverRefusesFallbackAndOversizedOutputIsRejected() async throws {
        let resolver = WebCredentials(environment: ["VERDICTUI_WEB_CRED_TEST": UUID().uuidString], onePassword: nil)
        try await resolver.close()
        do { _ = try await resolver.resolve("test"); XCTFail("closed resolver returned a fallback") }
        catch { XCTAssertEqual(error as? WebBrowserError, .credentialUnavailable) }
        let (root, executable) = try fixture()
        try "#!/bin/sh\nexec /usr/bin/head -c 65537 /dev/zero\n".write(to: executable, atomically: true, encoding: .utf8)
        let oversized = WebCredentials(environment: [:], sharedFile: root.appendingPathComponent("absent"), onePassword: executable)
        do { _ = try await oversized.resolve("test"); XCTFail("oversized credential accepted") }
        catch { XCTAssertEqual(error as? WebBrowserError, .credentialUnavailable) }
        try await oversized.close()
    }

    private func send(_ id: Int, tool: String, arguments: [String: Any], input: FileHandle) throws {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func reply(output: FileHandle) async throws -> Data {
        let data = try await Task.detached {
            var data = Data()
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                guard ready >= 0 else { throw CocoaError(.fileReadUnknown) }
                if ready == 0 { continue }
                guard let byte = try output.read(upToCount: 1), !byte.isEmpty else { throw CocoaError(.fileReadUnknown) }
                if byte == Data([10]) { return data }
                data.append(byte)
                guard data.count < 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
            }
            throw CocoaError(.fileReadUnknown)
        }.value
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertNotEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return Data(try XCTUnwrap(content.first?["text"] as? String).utf8)
    }

    func testMCPSIGTERMAwaitsInFlightCredentialGroupBeforeExit() async throws {
        let (root, executable) = try fixture()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try XCTUnwrap(Bundle.module.url(forResource: "login", withExtension: "html", subdirectory: "Fixtures"))
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = repository.appendingPathComponent(".build/debug/verdictui")
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["VERDICTUI_WEB_OP"] = executable.path
        environment["RESOLVER_ROOT"] = root.path
        environment["VERDICTUI_WEB_PROFILE_ROOT"] = root.appendingPathComponent("profiles").path
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        }
        try send(1, tool: "web_open", arguments: ["profile": "owned", "url": page.absoluteString], input: input.fileHandleForWriting)
        let openReply = try await reply(output: output.fileHandleForReading)
        let sessions = try XCTUnwrap(JSONSerialization.jsonObject(with: openReply) as? [[String: Any]])
        let browserPID = try XCTUnwrap(sessions.first?["pid"] as? Int32)
        try send(2, tool: "web_render", arguments: ["profile": "owned"], input: input.fileHandleForWriting)
        let renderReply = try await reply(output: output.fileHandleForReading)
        let tree = try XCTUnwrap(JSONSerialization.jsonObject(with: renderReply) as? [String: Any])
        let strings = try XCTUnwrap(tree["strings"] as? [String])
        let textIDs = try XCTUnwrap(tree["textIDs"] as? [Int])
        let ids = try XCTUnwrap(tree["ids"] as? [String])
        let password = try XCTUnwrap(textIDs.firstIndex { $0 >= 0 && strings[$0] == "Password" })
        try send(3, tool: "web_act", arguments: ["profile": "owned", "action": "credential", "node": ids[password], "credential": "test"], input: input.fileHandleForWriting)
        let leader = try await pid("leader", root: root)
        let child = try await pid("child", root: root)
        defer { for value in [child, leader] where getpgid(value) == leader { kill(value, SIGKILL) } }
        process.terminate()
        let deadline = ContinuousClock.now + .seconds(8)
        while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(process.isRunning)
        if !process.isRunning { XCTAssertEqual(process.terminationStatus, 128 + SIGTERM) }
        try await assertGone([leader, child, browserPID])
    }
}
