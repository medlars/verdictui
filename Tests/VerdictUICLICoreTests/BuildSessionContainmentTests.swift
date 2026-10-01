import Darwin
import Foundation
import XCTest

/// The installed CLI owns its consumer build as a session it created. A build
/// descendant that starts its own process group (as SwiftPM's manifest and
/// tools do) must not survive the CLI exiting, being interrupted, or SIGKILL.
/// Cleanup in these tests only ever targets members of the owned session.
final class BuildSessionContainmentTests: XCTestCase {
    private struct Identity { let pid: pid_t, group: pid_t, session: pid_t }
    private enum Failure: Error { case timeout, compile, listing }

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let cli = repository.appendingPathComponent(".build/debug/verdictui")

    private func project(packageName: String? = nil) throws -> URL {
        let name = packageName ?? "vui-session-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".verdictui"),
                                                withIntermediateDirectories: true)
        addTeardownBlock {
            // Releases fixture processes that containment failed to remove,
            // without signalling any discovered PID.
            FileManager.default.createFile(atPath: root.appendingPathComponent("release").path, contents: nil)
            Thread.sleep(forTimeInterval: 0.3)
            try? FileManager.default.removeItem(at: root)
        }
        let runner = root.appendingPathComponent("runner")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: runner)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
        return root
    }

    private func configure(_ root: URL, product: String) throws {
        let config: [String: Any] = ["runner": "runner", "buildProduct": product, "buildTimeoutSeconds": 600]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: root.appendingPathComponent(".verdictui/config.json"))
    }

    /// A fake `swift` on PATH: its child calls setpgid(0, 0) and forks a
    /// grandchild; both ignore TERM/INT/HUP, so only session cleanup removes them.
    private func fixtureSwift(in root: URL) throws -> URL {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fixture.c")
        try Self.fixtureSource.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = ["-Wall", "-Wextra", "-Werror", source.path, "-o", bin.appendingPathComponent("swift").path]
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw Failure.compile }
        return bin
    }

    private func launchCLI(root: URL, environment extra: [String: String] = [:]) throws -> Process {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Self.cli.path), "build the verdictui product first")
        let process = Process()
        process.executableURL = Self.cli
        process.arguments = ["list"]
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "VERDICTUI_PROJECT_RUNNER_DELEGATED")
        for (key, value) in extra { environment[key] = value }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: root.appendingPathComponent("cli.stderr").path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: root.appendingPathComponent("cli.stderr"))
        try process.run()
        return process
    }

    private func sentinel() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["120"]
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate() } }
        return process
    }

    private func record(_ name: String, in root: URL, seconds: TimeInterval = 20) throws -> Identity {
        let file = root.appendingPathComponent(name)
        guard waitUntil(seconds, { FileManager.default.fileExists(atPath: file.path) }) else { throw Failure.timeout }
        let values = try String(contentsOf: file, encoding: .utf8).split(separator: " ")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard values.count == 3 else { throw Failure.timeout }
        return Identity(pid: values[0], group: values[1], session: values[2])
    }

    private func assertFixtureTopology(_ root: URL, cli: Process) throws -> (Identity, Identity, Identity) {
        let leader = try record("leader", in: root), child = try record("child", in: root)
        let grandchild = try record("grandchild", in: root)
        XCTAssertEqual(leader.session, leader.pid, "the build leads a session created at launch")
        XCTAssertNotEqual(leader.session, getsid(cli.processIdentifier))
        XCTAssertNotEqual(leader.session, getsid(0), "never the test runner's session")
        XCTAssertEqual(child.group, child.pid, "the fixture child left the build's process group")
        XCTAssertNotEqual(child.group, leader.group)
        XCTAssertEqual(grandchild.group, child.pid)
        XCTAssertEqual(child.session, leader.session)
        XCTAssertEqual(grandchild.session, leader.session)
        return (leader, child, grandchild)
    }

    private func finish(_ cli: Process, root: URL, session: pid_t, sentinel: Process,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(waitUntil(15, { !cli.isRunning }), "CLI did not exit", file: file, line: line)
        // The CLI inherits this runner's session; a build that did not get its
        // own session must fail here, never be "cleaned up" by sweeping ours.
        guard session > 0, session != getsid(0) else {
            return XCTFail("build session \(session) is not one the launch created", file: file, line: line)
        }
        addTeardownBlock { _ = cleanUpOwnedSession(session) }
        var survivors: [pid_t] = []
        let contained = waitUntil(5, {
            guard let members = sessionMembers(session) else { return false }
            survivors = members
            return members.isEmpty
        })
        let stderr = (try? String(contentsOf: root.appendingPathComponent("cli.stderr"), encoding: .utf8)) ?? ""
        XCTAssertTrue(contained, "owned session \(session) survivors: \(survivors.map(describe)); stderr: \(stderr)",
                      file: file, line: line)
        XCTAssertTrue(sentinel.isRunning, "an unrelated process outside the owned session must survive",
                      file: file, line: line)
        print("BUILD-SESSION-CONTAINMENT session=\(session) survivors=\(survivors.count) sentinel=\(sentinel.isRunning)")
    }

    func testNormalCLIExitRemovesOwnGroupBuildDescendants() throws {
        let root = try project()
        try configure(root, product: "Fixture")
        let bin = try fixtureSwift(in: root)
        let sentinel = try sentinel()
        let cli = try launchCLI(root: root, environment: [
            "PATH": "\(bin.path):/usr/bin:/bin", "VUI_FIXTURE_ROOT": root.path, "VUI_FIXTURE_MODE": "exit"])
        let (leader, child, grandchild) = try assertFixtureTopology(root, cli: cli)
        try finish(cli, root: root, session: leader.session, sentinel: sentinel)
        XCTAssertEqual(cli.terminationReason, .exit)
        XCTAssertEqual(cli.terminationStatus, 0)
        XCTAssertFalse(alive(child.pid)); XCTAssertFalse(alive(grandchild.pid))
    }

    private func interrupt(_ number: Int32) throws {
        let root = try project()
        try configure(root, product: "Fixture")
        let bin = try fixtureSwift(in: root)
        let sentinel = try sentinel()
        let cli = try launchCLI(root: root, environment: [
            "PATH": "\(bin.path):/usr/bin:/bin", "VUI_FIXTURE_ROOT": root.path, "VUI_FIXTURE_MODE": "hang"])
        let (leader, child, grandchild) = try assertFixtureTopology(root, cli: cli)
        XCTAssertEqual(kill(cli.processIdentifier, number), 0)
        try finish(cli, root: root, session: leader.session, sentinel: sentinel)
        if number == SIGKILL {
            XCTAssertEqual(cli.terminationReason, .uncaughtSignal)
            XCTAssertEqual(cli.terminationStatus, SIGKILL)
        } else {
            XCTAssertEqual(cli.terminationReason, .exit, "the handler swept the session, then exited")
            XCTAssertEqual(cli.terminationStatus, 128 + number)
        }
        XCTAssertFalse(alive(child.pid)); XCTAssertFalse(alive(grandchild.pid))
    }

    func testSIGINTToCLIRemovesOwnGroupBuildDescendants() throws { try interrupt(SIGINT) }
    func testSIGTERMToCLIRemovesOwnGroupBuildDescendants() throws { try interrupt(SIGTERM) }
    func testSIGHUPToCLIRemovesOwnGroupBuildDescendants() throws { try interrupt(SIGHUP) }
    func testSIGKILLToCLIGuardianRemovesOwnGroupBuildDescendants() throws { try interrupt(SIGKILL) }

    /// Real SwiftPM: the evaluated manifest runs in its own process group (TSC
    /// spawns with a new group). Killing the CLI mid-evaluation must leave no
    /// member of the owned session and no manifest process anywhere.
    private func realSwiftPM(_ number: Int32) throws {
        let name = "vuicontain\(UUID().uuidString.prefix(8).lowercased())"
        let root = try project(packageName: name)
        try configure(root, product: name)
        let sources = root.appendingPathComponent("Sources/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "print(1)\n".write(to: sources.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try """
            // swift-tools-version: 5.9
            import PackageDescription
            import Foundation
            let release = "\(root.path)/release"
            let deadline = Date().addingTimeInterval(300)
            while !FileManager.default.fileExists(atPath: release), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            let package = Package(name: "\(name)", targets: [.executableTarget(name: "\(name)")])
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let sentinel = try sentinel()
        let cli = try launchCLI(root: root)
        addTeardownBlock { if cli.isRunning { kill(cli.processIdentifier, SIGKILL) } }
        var manifest: pid_t = 0
        XCTAssertTrue(waitUntil(240, {
            manifest = manifestProcesses(named: name).first ?? 0
            return manifest > 0
        }), "SwiftPM never began evaluating the manifest")
        guard manifest > 0 else { return }
        let session = getsid(manifest)
        XCTAssertGreaterThan(session, 0)
        XCTAssertEqual(getsid(session), session, "the manifest is in the session the CLI launched")
        XCTAssertNotEqual(session, getsid(cli.processIdentifier))
        XCTAssertEqual(getpgid(manifest), manifest, "the evaluated manifest leads its own process group")
        XCTAssertNotEqual(getpgid(manifest), getpgid(session))
        XCTAssertEqual(kill(cli.processIdentifier, number), 0)
        try finish(cli, root: root, session: session, sentinel: sentinel)
        XCTAssertEqual(manifestProcesses(named: name), [], "no evaluated manifest survives anywhere")
        print("REAL-SWIFTPM-CONTAINMENT signal=\(number) manifest=\(manifest) session=\(session) contained")
    }

    func testRealSwiftPMManifestEvaluationDiesWithCLISIGKILL() throws { try realSwiftPM(SIGKILL) }
    func testRealSwiftPMManifestEvaluationDiesWithCLISIGINT() throws { try realSwiftPM(SIGINT) }

    private static let fixtureSource = #"""
    #include <signal.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <unistd.h>
    static void record(const char *root, const char *name) {
        char path[4096], temporary[4096];
        snprintf(path, sizeof(path), "%s/%s", root, name);
        snprintf(temporary, sizeof(temporary), "%s/.%s.tmp", root, name);
        FILE *file = fopen(temporary, "w"); if (!file) _exit(90);
        fprintf(file, "%d %d %d\n", getpid(), getpgrp(), getsid(0)); fclose(file);
        if (rename(temporary, path)) _exit(91);
    }
    static int exists(const char *root, const char *name) {
        char path[4096]; snprintf(path, sizeof(path), "%s/%s", root, name);
        return access(path, F_OK) == 0;
    }
    static void stubborn(void) { signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN); }
    int main(void) {
        const char *root = getenv("VUI_FIXTURE_ROOT"), *mode = getenv("VUI_FIXTURE_MODE");
        if (!root || !mode) return 92;
        pid_t child = fork();
        if (child < 0) return 93;
        if (child == 0) {
            if (setpgid(0, 0) != 0) _exit(94);
            pid_t grandchild = fork();
            if (grandchild < 0) _exit(95);
            stubborn();
            record(root, grandchild == 0 ? "grandchild" : "child");
            while (!exists(root, "release")) usleep(50000);
            _exit(0);
        }
        for (int i = 0; i < 1000 && !(exists(root, "child") && exists(root, "grandchild")); ++i) usleep(10000);
        record(root, "leader");
        if (!strcmp(mode, "exit")) return 0;
        while (!exists(root, "release")) usleep(50000);
        return 0;
    }
    """#
}

private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    } while ContinuousClock.now < deadline
    return condition()
}

private func allProcesses() -> [pid_t]? {
    let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard bytes > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 1024)
    let capacity = Int32(pids.count * MemoryLayout<pid_t>.size)
    let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, capacity)
    guard filled > 0, filled < capacity else { return nil }
    return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
}

/// Live (non-zombie) members; nil when the process table cannot be listed.
private func sessionMembers(_ session: pid_t) -> [pid_t]? {
    allProcesses()?.filter { getsid($0) == session && alive($0) }
}

private func alive(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status != UInt32(SZOMB)
}

private func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

/// Observation only: SwiftPM names the evaluated manifest after the package directory.
private func manifestProcesses(named name: String) -> [pid_t] {
    (allProcesses() ?? []).filter { alive($0) && executablePath($0)?.hasSuffix("/\(name)-manifest") == true }
}

private func describe(_ pid: pid_t) -> String {
    "\(pid):\(executablePath(pid) ?? "?") pgid=\(getpgid(pid))"
}

/// Teardown only, scoped to the owned session; never a discovered PID alone.
private func cleanUpOwnedSession(_ session: pid_t) -> Int32 {
    guard session > 0, session != getsid(0), let members = sessionMembers(session), !members.isEmpty else { return 0 }
    for member in members where getsid(member) == session { kill(member, SIGKILL) }
    return Int32(members.count)
}
