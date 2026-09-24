import Darwin
import XCTest
import VerdictUIKernel
@testable import VerdictUIWeb

private actor CloseBarrier {
    private var labels: Set<String> = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func arrive(_ label: String) async {
        labels.insert(label)
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func count() -> Int { labels.count }
    func mark(_ label: String) { labels.insert(label) }
    func release() {
        released = true
        waiting.forEach { $0.resume() }; waiting.removeAll()
    }
}

private final class OrderlyBrowserIdentity: BrowserProcessIdentity, @unchecked Sendable {
    // Deliberately names a live unrelated process after our owned identity exits.
    let pid = ProcessInfo.processInfo.processIdentifier
    private let mutex = NSLock()
    private var running = true
    private var refusesFinish = false
    private var recorded: [String] = []
    private let profileLockPath: URL
    init(profileLockPath: URL) { self.profileLockPath = profileLockPath }
    var isRunning: Bool { mutex.withLock { running } }
    var events: [String] { mutex.withLock { recorded } }
    func orderlyExit() {
        mutex.withLock { recorded.append("profile-flushed"); running = false }
    }
    func record(_ event: String) { mutex.withLock { recorded.append(event) } }
    func signal(_ value: Int32) {
        mutex.withLock { recorded.append("signal-\(value)"); running = false }
    }
    func refuseFinish(_ value: Bool) { mutex.withLock { refusesFinish = value } }
    func finish() throws {
        record(FileManager.default.fileExists(atPath: profileLockPath.path) ? "finish-locked" : "finish-unlocked")
        if mutex.withLock({ refusesFinish }) { throw WebBrowserError.processRefusedToDie(pid: pid) }
    }
}

private actor OrderlyBrowserSocket: CDPSocket {
    enum Closed: Error { case socket }
    private let identity: OrderlyBrowserIdentity
    private var waiting: CheckedContinuation<String, any Error>?
    private var ended = false
    private let barrier: CloseBarrier?
    private let label: String
    init(identity: OrderlyBrowserIdentity, barrier: CloseBarrier? = nil, label: String = "") {
        self.identity = identity; self.barrier = barrier; self.label = label
    }
    func send(text: String) async throws {
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let method = try XCTUnwrap(request["method"] as? String)
        identity.record(method)
        if method == "Browser.close" {
            if let barrier { await barrier.arrive(label) }
            identity.orderlyExit()
        }
        // Chrome is allowed to close its socket without acknowledging Browser.close.
        ended = true
        waiting?.resume(throwing: Closed.socket); waiting = nil
    }
    func receive() async throws -> String {
        if ended { throw Closed.socket }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func close() {
        identity.record("socket-closed")
        ended = true
        waiting?.resume(throwing: Closed.socket); waiting = nil
    }
}

@MainActor
final class WebCredentialLifecycleTests: XCTestCase {
    func testFailedRetirementRetainsOwnerForRetryAcrossListOpenAndLookup() async throws {
        for operation in ["list", "open", "render"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("verdictui-retirement-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let lock = try ProfileLock.acquire(profile: "owned", registry: ProfileRegistry(root: root))
            let identity = OrderlyBrowserIdentity(profileLockPath: lock.path)
            identity.refuseFinish(true)
            let browser = HeadlessBrowser(process: identity,
                endpoint: DevtoolsEndpoint(port: 12345, browserPath: "/devtools/browser/fixture"), profileDirectory: root)
            let url = URL(fileURLWithPath: "/fixture")
            // Keep an independent fixture reference so deinit's best-effort cleanup
            // cannot conceal manager ownership loss in the failing control.
            let session = WebSession(profile: "owned", browser: browser,
                transport: CDPTransport(socket: OrderlyBrowserSocket(identity: identity)),
                pageSessionID: "fixture", lock: lock, credentials: WebCredentials(environment: [:], onePassword: nil),
                viewport: Rect(x: 0, y: 0, width: 1280, height: 800), url: url)
            let opened = CloseBarrier()
            let manager = WebSessionManager(root: root) { _, _, _, _, _, _ in
                await opened.mark(UUID().uuidString)
                return session
            }
            _ = try await manager.open(profile: "owned", url: url)
            identity.orderlyExit()
            if operation == "list" {
                let available = await manager.list()
                XCTAssertTrue(available.isEmpty)
            } else {
                do {
                    if operation == "open" { _ = try await manager.open(profile: "owned", url: url) }
                    else { _ = try await manager.render(profile: "owned") }
                    XCTFail("failed cleanup must make \(operation) unavailable")
                } catch { XCTAssertEqual(error as? WebBrowserError, .processRefusedToDie(pid: identity.pid)) }
            }
            let beforeRetry = identity.events.filter { $0.hasPrefix("finish-") }.count
            XCTAssertGreaterThan(beforeRetry, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path.path))
            identity.refuseFinish(false)
            let failures = await manager.closeAll()
            XCTAssertTrue(failures.isEmpty)
            XCTAssertGreaterThan(identity.events.filter { $0.hasPrefix("finish-") }.count, beforeRetry,
                                 "\(operation) discarded the manager's cleanup retry owner")
            XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path.path))
            let opens = await opened.count()
            XCTAssertEqual(opens, 1, "failed cleanup must not launch a replacement")
            try await session.close()
        }
    }

    func testManagerCoalescesConcurrentShutdownAndDrainsPendingAndOpenSessionsTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verdictui-manager-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let barrier = CloseBarrier(), started = CloseBarrier(), finished = CloseBarrier()
        let registry = ProfileRegistry(root: root)
        let url = URL(fileURLWithPath: "/fixture")
        var sessions: [String: WebSession] = [:]
        var identities: [OrderlyBrowserIdentity] = []
        for name in ["one", "two", "pending"] {
            let lock = try ProfileLock.acquire(profile: name, registry: registry)
            let identity = OrderlyBrowserIdentity(profileLockPath: lock.path)
            identities.append(identity)
            let browser = HeadlessBrowser(process: identity,
                endpoint: DevtoolsEndpoint(port: 12345, browserPath: "/devtools/browser/fixture"), profileDirectory: root)
            sessions[name] = WebSession(profile: name, browser: browser,
                transport: CDPTransport(socket: OrderlyBrowserSocket(identity: identity, barrier: barrier, label: name)),
                pageSessionID: "fixture", lock: lock, credentials: WebCredentials(environment: [:], onePassword: nil),
                viewport: Rect(x: 0, y: 0, width: 1280, height: 800), url: url)
        }
        let ready = sessions
        let manager = WebSessionManager(root: root) { name, _, _, _, _, _ in
            if name == "pending" {
                await started.arrive("opening")
                // Model a launch publishing just as cancellation reaches it.
            }
            return try XCTUnwrap(ready[name])
        }
        _ = try await manager.open(profile: "one", url: url)
        _ = try await manager.open(profile: "two", url: url)
        let opening = Task { try await manager.open(profile: "pending", url: url) }
        let deadline = ContinuousClock.now + .seconds(2)
        while await started.count() == 0, ContinuousClock.now < deadline { await Task.yield() }
        let startedCount = await started.count()
        XCTAssertEqual(startedCount, 1)
        let first = Task { let failures = await manager.closeAll(); await finished.mark("first"); return failures }
        let second = Task { let failures = await manager.closeAll(); await finished.mark("second"); return failures }
        let existingDeadline = ContinuousClock.now + .seconds(1.5)
        while await barrier.count() < 2, ContinuousClock.now < existingDeadline { await Task.yield() }
        let existingCount = await barrier.count()
        XCTAssertEqual(existingCount, 2, "a pending launch must not delay existing profile close")
        await started.release()
        let closingDeadline = ContinuousClock.now + .seconds(1.5)
        while await barrier.count() < 3, ContinuousClock.now < closingDeadline { await Task.yield() }
        let closingCount = await barrier.count()
        XCTAssertEqual(closingCount, 3, "pending launch and every open session must begin closing together")
        let prematureReturns = await finished.count()
        XCTAssertEqual(prematureReturns, 0, "a concurrent closeAll returned before shared cleanup finished")
        await barrier.release()
        let firstFailures = await first.value, secondFailures = await second.value
        XCTAssertTrue(firstFailures.isEmpty && secondFailures.isEmpty)
        do { _ = try await opening.value; XCTFail("shutdown published a pending session") } catch {}
        for identity in identities {
            XCTAssertEqual(identity.events.filter { $0 == "Browser.close" }.count, 1)
            XCTAssertTrue(identity.events.contains("finish-locked"))
            XCTAssertFalse(identity.events.contains { $0.hasPrefix("signal-") })
        }
        let remaining = await manager.list()
        XCTAssertTrue(remaining.isEmpty)
        do { _ = try await manager.open(profile: "one", url: url); XCTFail("stopped manager opened again") } catch {}
    }

    func testSessionCloseFlushesBeforeDisconnectAndProfileReleaseWithoutAReply() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verdictui-close-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProfileRegistry(root: root)
        let lock = try ProfileLock.acquire(profile: "orderly", registry: registry)
        let identity = OrderlyBrowserIdentity(profileLockPath: lock.path)
        let browser = HeadlessBrowser(process: identity,
            endpoint: DevtoolsEndpoint(port: 12345, browserPath: "/devtools/browser/fixture"), profileDirectory: root)
        let transport = CDPTransport(socket: OrderlyBrowserSocket(identity: identity))
        let session = WebSession(profile: "orderly", browser: browser, transport: transport,
            pageSessionID: "fixture", lock: lock, credentials: WebCredentials(environment: [:], onePassword: nil),
            viewport: Rect(x: 0, y: 0, width: 1280, height: 800), url: URL(fileURLWithPath: "/fixture"))
        try await session.close()
        let events = identity.events
        XCTAssertEqual(events.first, "Browser.close")
        XCTAssertTrue(events.contains("profile-flushed"), "normal close must request Chrome's storage flush")
        XCTAssertFalse(events.contains { $0.hasPrefix("signal-") }, "an orderly exited child needs no signal")
        let flushed = try XCTUnwrap(events.firstIndex(of: "profile-flushed"))
        let disconnected = try XCTUnwrap(events.firstIndex(of: "socket-closed"))
        XCTAssertLessThan(flushed, disconnected, "closing the transport first prevents orderly shutdown")
        XCTAssertTrue(events.contains("finish-locked"), "retain profile ownership through descendant cleanup")
        XCTAssertFalse(events.contains("finish-unlocked"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path.path))
        let reopened = try ProfileLock.acquire(profile: "orderly", registry: registry)
        reopened.release()
        XCTAssertTrue(ProcessLiveness.isAlive(identity.pid), "the unrelated recycled PID remains live")
        let exited = await browser.awaitExit(within: 0)
        XCTAssertTrue(exited, "exit observation must consult the retained child, not the live recycled PID")
    }

    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verdictui-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            // Private capability cleanup works even for the unguarded RED control.
            // The fixture owns/reaps its child; observed PIDs never authorize signals.
            try Data().write(to: root.appendingPathComponent("release"))
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                let text = try? String(contentsOf: root.appendingPathComponent("leader.pid"), encoding: .utf8)
                guard let text, let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                      ProcessLiveness.isAlive(value) else { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try? FileManager.default.removeItem(at: root)
        }
        let executable = root.appendingPathComponent("op")
        let script = #"""
        #!/usr/bin/env python3
        import os,pathlib,signal,subprocess,time
        root=pathlib.Path(os.environ['RESOLVER_ROOT'])
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        child=subprocess.Popen(['/bin/sleep','60'])
        (root/'leader.pid').write_text(str(os.getpid()))
        (root/'child.pid').write_text(str(child.pid))
        try:
            deadline=time.monotonic()+60
            while not (root/'release').exists() and time.monotonic()<deadline:time.sleep(.02)
        finally:
            child.kill();child.wait()
        """#
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
            XCTAssertEqual(getpgid(child), getpgid(leader))
            XCTAssertNotEqual(getpgid(leader), getpgrp())
            let cancellationStart = ContinuousClock.now
            if cancel { operation.cancel() }
            else {
                let firstClose = Task { try await resolver.close() }
                try await Task.sleep(for: .milliseconds(50))
                try await resolver.close()
                XCTAssertFalse(ProcessLiveness.isAlive(leader), "concurrent resolver close returned before cleanup")
                try await firstClose.value
            }
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
        try await exerciseMCPShutdown(crash: false)
    }

    func testMCPSIGKILLContainsCredentialDescendantAndPreservesSentinel() async throws {
        try await exerciseMCPShutdown(crash: true)
    }

    func testMCPSIGTERMAwaitsPermittedLateBrowserExit() async throws {
        try await exerciseMCPShutdown(crash: false, delayedBrowserExit: true)
    }

    private func exerciseMCPShutdown(crash: Bool, delayedBrowserExit: Bool = false) async throws {
        let (root, executable) = try fixture()
        let sentinel = Process()
        sentinel.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sentinel.arguments = ["60"]
        try sentinel.run()
        defer { if sentinel.isRunning { sentinel.terminate() }; sentinel.waitUntilExit() }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try XCTUnwrap(Bundle.module.url(forResource: "login", withExtension: "html", subdirectory: "Fixtures"))
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = repository.appendingPathComponent(".build/debug/verdictui")
        process.arguments = ["mcp"]
        // Isolate the credential lifecycle from the repository's runner manifest.
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["VERDICTUI_WEB_OP"] = executable.path
        environment["RESOLVER_ROOT"] = root.path
        environment["VERDICTUI_WEB_PROFILE_ROOT"] = root.appendingPathComponent("profiles").path
        if delayedBrowserExit {
            let wrapper = root.appendingPathComponent("delayed-browser")
            let script = #"""
            #!/usr/bin/env python3
            import json,os,pathlib,subprocess,sys,threading,time
            root=pathlib.Path(os.environ['RESOLVER_ROOT'])
            browser=subprocess.Popen([os.environ['LIFECYCLE_REAL_BROWSER'],*sys.argv[1:]])
            code=browser.wait()
            exited=time.clock_gettime(time.CLOCK_MONOTONIC)
            (root/'browser-exit.json').write_text(json.dumps({'code':code,'at':exited}))
            # Bound the injected total delay, rather than adding nine seconds
            # after Chrome's variable exit latency. Swift publishes this start
            # atomically before SIGTERM using the same monotonic clock.
            started=float((root/'shutdown-requested').read_text())
            deadline=started+9
            threading.Event().wait(max(0,deadline-time.clock_gettime(time.CLOCK_MONOTONIC)))
            finished=time.clock_gettime(time.CLOCK_MONOTONIC)
            (root/'wrapper-timing.json').write_text(json.dumps({'started':started,'deadline':deadline,'finished':finished}))
            (root/'wrapper-exited').write_text('normal')
            raise SystemExit(code)
            """#
            try script.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            environment["LIFECYCLE_REAL_BROWSER"] = try BrowserLocator.locate(environment: ProcessInfo.processInfo.environment).path
            environment["VERDICTUI_WEB_BROWSER"] = wrapper.path
        }
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
        let shutdownStart = try monotonicTime()
        if delayedBrowserExit {
            try String(shutdownStart).write(to: root.appendingPathComponent("shutdown-requested"), atomically: true, encoding: .utf8)
        }
        if crash { XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0) }
        else { process.terminate() }
        // Orderly exit includes credentials, Chrome's own close and retained
        // guardian cleanup. The crash witness keeps its separate short bound.
        let shutdownAllowance = crash ? 8 : WebSession.consumerShutdownGrace
        let deadline = shutdownStart + shutdownAllowance
        while process.isRunning {
            if try monotonicTime() >= deadline { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(process.isRunning)
        if !process.isRunning { XCTAssertEqual(process.terminationStatus, crash ? SIGKILL : 128 + SIGTERM) }
        try await assertGone([leader, child, browserPID])
        if delayedBrowserExit {
            let observed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("browser-exit.json"))) as? [String: Double])
            XCTAssertEqual(observed["code"], 0, "real Chrome must complete its own shutdown")
            let browserExit = try XCTUnwrap(observed["at"])
            let timing = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("wrapper-timing.json"))) as? [String: Double])
            XCTAssertEqual(timing["started"], shutdownStart)
            XCTAssertEqual(timing["deadline"], shutdownStart + 9)
            XCTAssertLessThan(browserExit, shutdownStart + 9, "Chrome must exit before the injected late-exit deadline")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(timing["finished"]), shutdownStart + 9,
                "the wrapper must actually exercise late orderly exit")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("wrapper-exited"), encoding: .utf8), "normal",
                "the permitted late-exit wrapper must finish without forced termination")
        }
        XCTAssertTrue(sentinel.isRunning, "resolver cleanup touched an unrelated retained sentinel")
    }

    private func monotonicTime() throws -> TimeInterval {
        var value = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &value) == 0 else { throw POSIXError(.EIO) }
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }
}
