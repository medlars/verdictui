import Foundation
import XCTest

@testable import VerdictUICLICore

final class ProjectRunnerBrokerTests: XCTestCase {
    private func fixture(
        _ wire: ProjectRunnerBroker.Wire = .mcp, build: ProjectRunnerBroker.Session.Build? = nil
    ) throws -> (
        URL, ProjectRunnerBroker.Session
    ) {
        let root = URL(fileURLWithPath: "/tmp/vui-broker-test-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(".verdictui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runner = directory.appendingPathComponent("runner")
        try Data("one".utf8).write(to: root.appendingPathComponent("source.txt"))
        try Data(#"{"runner":".verdictui/runner"}"#.utf8).write(
            to: directory.appendingPathComponent("config.json"))
        let script = #"""
            #!/usr/bin/env python3
            import json,os,sys,socket,subprocess
            value=open('source.txt').read()
            initialized=False
            descendant=None
            def answer(line):
                global initialized,descendant
                request=json.loads(line)
                if request.get("method")=="spawn":descendant=subprocess.Popen(["/bin/sleep","60"]).pid
                if request.get("method")=="initialize":initialized=True
                if request.get("method")=="mutate":open("source.txt","w").write("changed-during-request")
                if request.get("method")=="malformed":return "not-json\n"
                if request.get('method')=='crash':os._exit(73)
                if 'id' not in request and sys.argv[1]=='mcp':return None
                result={'value':value,'pid':os.getpid(),'initialized':initialized,'descendant':descendant}
                return json.dumps({'jsonrpc':'2.0','id':request.get('id'),'result':result,'ok':True})+'\n'
            if sys.argv[1]=='mcp':
                for line in sys.stdin:
                    result=answer(line)
                    if result: print(result,end='',flush=True)
            else:
                server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
                server.bind(sys.argv[-1]);server.listen()
                while True:
                    connection,_=server.accept()
                    with connection:
                        stream=connection.makefile('rb')
                        for line in stream:
                            result=answer(line)
                            if result:connection.sendall(result.encode())
            """#
        try Data(script.utf8).write(to: runner)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
        let session = ProjectRunnerBroker.Session(
            destination: .init(executable: runner, projectRoot: root), wire: wire, build: build)
        addTeardownBlock {
            session.stop()
            try? FileManager.default.removeItem(at: root)
        }
        return (root, session)
    }

    private func answer(
        _ session: ProjectRunnerBroker.Session, method: String = "tools/call", id: Int = 1
    ) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method])
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(session.answer(data))) as? [String: Any])
    }
    private func value(_ response: [String: Any]) -> String? {
        (response["result"] as? [String: Any])?["value"] as? String
    }

    func testUnchangedRequestsReuseChildAndSourceEditRestartsIt() throws {
        let (root, session) = try fixture()
        XCTAssertEqual(value(try answer(session, method: "initialize")), "one")
        let pid = try XCTUnwrap(session.child?.processIdentifier)
        XCTAssertEqual(value(try answer(session)), "one")
        XCTAssertEqual(session.child?.processIdentifier, pid)
        try Data("two".utf8).write(to: root.appendingPathComponent("source.txt"))
        let reloaded = try answer(session)
        XCTAssertEqual(value(reloaded), "two")
        XCTAssertEqual((reloaded["result"] as? [String: Any])?["initialized"] as? Bool, true)
        XCTAssertNotEqual(session.child?.processIdentifier, pid)
    }

    func testKilledChildReportsUnavailableThenNextRequestRecovers() throws {
        let (_, session) = try fixture()
        _ = try answer(session)
        let child = try XCTUnwrap(session.child)
        kill(child.processIdentifier, SIGKILL)
        let deadline = Date.timeIntervalSinceReferenceDate + 2
        while try child.status() == nil && Date.timeIntervalSinceReferenceDate < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let unavailable = try answer(session)
        XCTAssertEqual((unavailable["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual(value(try answer(session)), "one")
    }

    func testDeathDuringRequestNeverReplaysActionAndNextRequestRecovers() throws {
        let (_, session) = try fixture()
        _ = try answer(session)
        let unavailable = try answer(session, method: "crash")
        XCTAssertNotNil(unavailable["error"])
        XCTAssertNil(session.child)
        XCTAssertEqual(value(try answer(session)), "one")
    }

    func testFailedBuildDoesNotAnswerFromOldHost() throws {
        let (root, session) = try fixture()
        XCTAssertEqual(value(try answer(session)), "one")
        let package =
            "// swift-tools-version: 5.10\nimport PackageDescription\nlet package = Package(name: \"NoProducts\", targets: [])\n"
        try Data(package.utf8).write(to: root.appendingPathComponent("Package.swift"))
        let config = root.appendingPathComponent(".verdictui/config.json")
        try Data(#"{"runner":".verdictui/runner","buildProduct":"MissingProduct"}"#.utf8).write(
            to: config)
        let response = try answer(session)
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertNil(session.child)
        try Data(#"{"runner":".verdictui/runner"}"#.utf8).write(to: config)
        XCTAssertEqual(value(try answer(session)), "one")
    }

    func testBuildDirectoryNoiseDoesNotRestartHost() throws {
        let (root, session) = try fixture()
        _ = try answer(session)
        let pid = session.child?.processIdentifier
        let build = root.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("noise".utf8).write(to: build.appendingPathComponent("progress"))
        XCTAssertEqual(value(try answer(session)), "one")
        XCTAssertEqual(session.child?.processIdentifier, pid)
    }

    func testDaemonChildReloadAndCrashRecovery() throws {
        let (root, session) = try fixture(.daemon)
        XCTAssertEqual(value(try answer(session)), "one")
        try Data("two".utf8).write(to: root.appendingPathComponent("source.txt"))
        XCTAssertEqual(value(try answer(session)), "two")
        XCTAssertEqual(try answer(session, method: "crash")["ok"] as? Bool, false)
        XCTAssertEqual(value(try answer(session)), "two")
    }

    func testNotificationHasNoReply() throws {
        let (_, session) = try fixture()
        XCTAssertNil(session.answer(Data(#"{"method":"notifications/initialized"}"#.utf8)))
        XCTAssertEqual(value(try answer(session)), "one")
    }

    func testStockRoutingMarkerBypassesOnlyDaemonStart() {
        let environment = ["VERDICTUI_STOCK_DAEMON": "1"]
        XCTAssertTrue(
            ProjectRunner.isStockDaemon(
                arguments: ["daemon", "start", "--socket", "/tmp/owned.sock"],
                environment: environment))
        XCTAssertFalse(ProjectRunner.isStockDaemon(arguments: ["mcp"], environment: environment))
        XCTAssertFalse(
            ProjectRunner.isStockDaemon(arguments: ["daemon", "stop"], environment: environment))
        XCTAssertFalse(
            ProjectRunner.isStockDaemon(arguments: ["daemon", "start"], environment: [:]))
    }
    func testSourceChangeDuringRequestDiscardsOldResult() throws {
        let (_, session) = try fixture()
        _ = try answer(session)
        XCTAssertNotNil(try answer(session, method: "mutate")["error"])
        XCTAssertEqual(value(try answer(session)), "changed-during-request")
    }

    func testMalformedChildAnswerCannotMasqueradeAsVerdict() throws {
        let (_, session) = try fixture()
        _ = try answer(session)
        XCTAssertNotNil(try answer(session, method: "malformed")["error"])
        XCTAssertNil(session.child)
    }

    func testExternalBuildProductReplacementRestartsChild() throws {
        let (_, session) = try fixture()
        _ = try answer(session)
        let pid = session.child?.processIdentifier
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(1)],
            ofItemAtPath: session.destination.executable.path)
        XCTAssertEqual(value(try answer(session)), "one")
        XCTAssertNotEqual(session.child?.processIdentifier, pid)
    }

    func testChangedRunnerConfigurationNeverUsesPreviousExecutable() throws {
        let (root, session) = try fixture()
        _ = try answer(session)
        try Data(#"{"runner":".verdictui/other"}"#.utf8).write(
            to: root.appendingPathComponent(".verdictui/config.json"))
        let response = try answer(session)
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertNil(session.child)
    }

    func testKilledLeaderCannotLeaveItsDescendantRunning() throws {
        let (_, session) = try fixture()
        let result = try answer(session, method: "spawn")["result"] as? [String: Any]
        let descendant = try XCTUnwrap(result?["descendant"] as? Int32)
        let leader = try XCTUnwrap(session.child?.processIdentifier)
        defer { if getpgid(descendant) == leader { kill(descendant, SIGKILL) } }
        kill(leader, SIGKILL)
        Thread.sleep(forTimeInterval: 0.1)
        _ = try answer(session)
        let deadline = Date.timeIntervalSinceReferenceDate + 3
        while kill(descendant, 0) == 0 && Date.timeIntervalSinceReferenceDate < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(kill(descendant, 0), -1)
        XCTAssertEqual(value(try answer(session)), "one")
    }

    func testSourceMutationDuringBuildCannotCertifyMixedGeneration() throws {
        let (_, session) = try fixture(build: { root, _ in
            try Data("changed-by-build".utf8).write(to: root.appendingPathComponent("source.txt"))
        })
        let result = try answer(session)
        XCTAssertEqual((result["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertNil(session.child)
    }

    func testRepeatedFailedBuildsAreBoundedUntilInputChanges() throws {
        var calls = 0
        let (root, session) = try fixture(build: { _, _ in
            calls += 1
            throw ProjectRunnerBroker.Failure("controlled build failure")
        })
        _ = try answer(session)
        _ = try answer(session)
        XCTAssertEqual(calls, 1)
        try Data("changed".utf8).write(to: root.appendingPathComponent("source.txt"))
        _ = try answer(session)
        XCTAssertEqual(calls, 2)
    }

    func testDaemonOptionsAreValidatedInsteadOfSilentlyIgnored() throws {
        let root = URL(fileURLWithPath: "/tmp/consumer")
        XCTAssertEqual(try ProjectRunnerBroker.daemonSocket(arguments: ["daemon", "--socket", "/tmp/custom.sock"], root: root), "/tmp/custom.sock")
        XCTAssertEqual(try ProjectRunnerBroker.daemonSocket(arguments: ["daemon", "stop", "--socket=/tmp/custom.sock"], root: root), "/tmp/custom.sock")
        for arguments in [["daemon", "--socket"], ["daemon", "--socket="], ["daemon", "start", "--unknown"], ["daemon", "stop", "--socket", "--unknown"]] {
            XCTAssertThrowsError(try ProjectRunnerBroker.daemonSocket(arguments: arguments, root: root))
        }
    }

    func testGeneratedTreesAreIgnoredButResourceEditsInvalidateGeneration() throws {
        let (root, session) = try fixture()
        let initial = try session.fingerprint()
        for directory in ["dist", "build", "DerivedData", "Pods", ".worktrees", "Product.app"] {
            let output = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data("output".utf8).write(to: output.appendingPathComponent("generated.txt"))
        }
        XCTAssertEqual(try session.fingerprint(), initial)
        let resource = root.appendingPathComponent("asset.png")
        try Data(repeating: 1, count: 131_073).write(to: resource)
        let withAsset = try session.fingerprint()
        XCTAssertNotEqual(withAsset, initial)
        try Data(repeating: 2, count: 131_073).write(to: resource)
        XCTAssertNotEqual(try session.fingerprint(), withAsset)
    }

    func testSourceScanBudgetsRefuseExcessDataAndTime() throws {
        let (root, session) = try fixture()
        try Data(repeating: 1, count: 131_073).write(to: root.appendingPathComponent("asset.bin"))
        XCTAssertThrowsError(try session.fingerprint(maximumBytes: 65_536))
        XCTAssertThrowsError(try session.fingerprint(maximumEntries: 1))
        XCTAssertThrowsError(try session.fingerprint(timeout: 0))
    }

    private func assertSlowSocketCloses(_ fragment: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let (_, session) = try fixture(.daemon)
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let client = pair[0], server = pair[1]
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        XCTAssertEqual(setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)), 0)
        let ended = expectation(description: "bounded socket frame")
        DispatchQueue.global().async {
            defer { Darwin.close(server); ended.fulfill() }
            try? ProjectRunnerBroker.serve(input: server, output: server, session: session,
                persistent: false, frameSeconds: 0.15)
        }
        let started = ProcessInfo.processInfo.systemUptime
        var disconnected = false
        while ProcessInfo.processInfo.systemUptime - started < 1 {
            let sent = fragment.withCString { write(client, $0, fragment.utf8.count) }
            if sent < 0 { disconnected = true; break }
            var ready = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            if poll(&ready, 1, 20) > 0 {
                var byte: UInt8 = 0
                if read(client, &byte, 1) <= 0 { disconnected = true; break }
            }
        }
        XCTAssertTrue(disconnected, "slow sender retained the serialized daemon connection", file: file, line: line)
        shutdown(client, SHUT_RDWR)
        wait(for: [ended], timeout: 2)
    }

    func testDrippedIncompleteSocketFrameHasAbsoluteDeadline() throws {
        try assertSlowSocketCloses(" ")
    }

    func testEmptyLinesCannotExtendSocketFrameDeadline() throws {
        try assertSlowSocketCloses("\n")
    }

    func testPersistentMCPRemainsUsableAfterFrameBudgetIdle() throws {
        let (_, session) = try fixture()
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let client = pair[0], server = pair[1]
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        XCTAssertEqual(setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)), 0)
        let ended = expectation(description: "persistent client closed")
        DispatchQueue.global().async {
            defer { Darwin.close(server); ended.fulfill() }
            try? ProjectRunnerBroker.serve(input: server, output: server, session: session,
                persistent: true, frameSeconds: 0.01)
        }
        var ready = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&ready, 1, 250), 0, "idle MCP was closed")
        let request = #"{"id":1,"method":"tools/call"}"# + "\n"
        _ = request.withCString { write(client, $0, request.utf8.count) }
        XCTAssertGreaterThan(poll(&ready, 1, 2_000), 0)
        var response = [UInt8](repeating: 0, count: 4096)
        let count = read(client, &response, response.count)
        XCTAssertGreaterThan(count, 0)
        if count > 0 {
            let object = try JSONSerialization.jsonObject(with: Data(response.prefix(count))) as? [String: Any]
            XCTAssertEqual((object?["result"] as? [String: Any])?["value"] as? String, "one")
        }
        shutdown(client, SHUT_RDWR)
        wait(for: [ended], timeout: 2)
    }

}
