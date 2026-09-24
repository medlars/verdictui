import Darwin
import Foundation
import XCTest
import VerdictUIProcessGuardian
@testable import VerdictUIWeb

final class BrowserCrashGuardianTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let executable: URL
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("verdictui-guardian-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            executable = directory.appendingPathComponent("fixture")
            let source = directory.appendingPathComponent("fixture.c")
            try fixtureSource.write(to: source, atomically: true, encoding: .utf8)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            compiler.arguments = ["-Wall", "-Wextra", "-Werror", "-I", root.appendingPathComponent("Sources/VerdictUIProcessGuardian/include").path,
                source.path, root.appendingPathComponent("Sources/VerdictUIProcessGuardian/ProcessGuardian.c").path, "-o", executable.path]
            try compiler.run()
            guard waitUntil(10, { !compiler.isRunning }) else {
                compiler.terminate(); throw Failure.timeout
            }
            guard compiler.terminationStatus == 0 else { throw Failure.compile }
        }
        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func record(_ name: String) throws -> [Int32] {
            guard waitUntil(4, { ((try? String(contentsOf: file(name), encoding: .utf8)) ?? "").contains("\n") }),
                  let value = try? String(contentsOf: file(name), encoding: .utf8) else { throw Failure.timeout }
            let values = value.split(separator: " ").compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard !values.isEmpty else { throw Failure.timeout }
            return values
        }
        func owner(_ mode: String = "owner") throws -> Process {
            let process = Process(); process.executableURL = executable
            process.arguments = [mode, directory.path]
            try process.run()
            return process
        }
        func browser() throws -> LaunchedBrowserProcess {
            try LaunchedBrowserProcess.launch(executable: executable,
                arguments: ["browser", directory.path], environment: [:])
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
    private enum Failure: Error { case timeout, compile }

    func testParentSIGKILLReapsBrowserGroupWithoutTouchingUnrelatedSentinel() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let sentinel = try fixture.owner("sentinel")
        defer { sentinel.terminate() }
        let owner = try fixture.owner()
        defer { if owner.isRunning { owner.terminate() } }
        let launch = try fixture.record("launched"), browser = try fixture.record("browser"), leaf = try fixture.record("leaf")
        XCTAssertEqual(browser[1], launch[0]); XCTAssertEqual(leaf[1], launch[0])
        XCTAssertNotEqual(browser[0], launch[0], "public PID is the actual browser, not guardian")
        XCTAssertEqual(kill(owner.processIdentifier, SIGKILL), 0)
        XCTAssertTrue(waitUntil(4, { !active(browser[0]) && !active(leaf[0]) && !active(launch[0]) }))
        XCTAssertTrue(sentinel.isRunning, "unrelated processes must survive group cleanup")
    }

    func testLeakedWriterCannotDefeatActualParentDeath() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let owner = try fixture.owner("leak")
        defer { if owner.isRunning { owner.terminate() } }
        let browser = try fixture.record("browser"), leaf = try fixture.record("leaf"), leaked = try fixture.record("leaked")
        XCTAssertEqual(kill(owner.processIdentifier, SIGKILL), 0)
        XCTAssertTrue(waitUntil(4, { !active(browser[0]) && !active(leaf[0]) }))
        XCTAssertTrue(active(leaked[0]), "leaked writer fixture must still be alive when containment succeeds")
        try Data().write(to: fixture.file("release-leaked"))
        XCTAssertTrue(waitUntil(2, { !active(leaked[0]) }))
    }

    func testBrowserFirstExitCleansDescendantAndReleasesRetainedChildren() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let browser = try fixture.browser(); defer { try? browser.finish() }
        let record = try fixture.record("browser"), leaf = try fixture.record("leaf")
        XCTAssertEqual(browser.pid, record[0])
        try Data().write(to: fixture.file("exit-browser"))
        XCTAssertTrue(waitUntil(4, { !active(leaf[0]) }))
        try browser.finish()
        var info = siginfo_t()
        XCTAssertEqual(waitid(P_PID, id_t(browser.pid), &info, WEXITED | WNOHANG | WNOWAIT), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testSoleLifetimeWriterCloseCleansGroupWhileParentStaysAlive() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let launched = try OwnedCommandProcess.spawnGuardedBrowser(executable: fixture.executable,
            arguments: ["browser", fixture.directory.path], environment: [:])
        defer { try? launched.guardian.finishGuardian(); try? launched.browser.finishBrowser() }
        let leaf = try fixture.record("leaf")
        close(launched.lifetimeWriter)
        XCTAssertTrue(waitUntil(4, { !active(launched.guardian.processIdentifier) && !active(leaf[0]) }))
        XCTAssertTrue(active(ProcessInfo.processInfo.processIdentifier))
    }

    func testExplicitCloseWaitsForTERMResistantDescendant() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let browser = try fixture.browser(); defer { try? browser.finish() }
        let leaf = try fixture.record("leaf")
        try browser.signal(SIGTERM)
        try browser.finish()
        XCTAssertFalse(active(leaf[0]), "successful close cannot release a profile while descendants are active")
    }

    func testDiscoveryTimeoutCleansStartedBrowserAndDescendant() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        do {
            _ = try await HeadlessBrowser.launch(.init(browser: fixture.executable,
                profileDirectory: fixture.directory, discoveryTimeout: 0.3))
            XCTFail("fixture deliberately never publishes DevToolsActivePort")
        } catch WebBrowserError.devtoolsNotDiscovered { }
        let browser = try fixture.record("browser"), leaf = try fixture.record("leaf")
        XCTAssertFalse(active(browser[0])); XCTAssertFalse(active(leaf[0]))
    }

    func testExecFailureReturnsTypedFailure() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let bad = fixture.file("invalid-exec")
        try Data("not an executable".utf8).write(to: bad)
        XCTAssertEqual(chmod(bad.path, 0o700), 0)
        XCTAssertThrowsError(try LaunchedBrowserProcess.launch(executable: bad, arguments: [], environment: [:])) { error in
            guard case OwnedCommandProcess.Failure.system(let code) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, ENOEXEC)
        }
    }

    func testOwnerDeathDuringHandshakeNeverStartsBrowser() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let owner = try fixture.owner("launch-death")
        defer { if owner.isRunning { owner.terminate() } }
        let guardian = try fixture.record("before-ready")
        XCTAssertEqual(kill(owner.processIdentifier, SIGKILL), 0)
        XCTAssertTrue(waitUntil(4, { !active(guardian[0]) }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file("browser").path))
    }

    func testDescriptorsAboveLoweredLimitAreClosedAndBrowserSignalsReset() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let owner = try fixture.owner("high-fd")
        defer { if owner.isRunning { owner.terminate() } }
        let launch = try fixture.record("launched"), browser = try fixture.record("browser")
        XCTAssertEqual(browser[2], 0, "browser inherited no fixture fd 7000")
        XCTAssertEqual(browser[3], 1, "browser signal defaults and mask are restored")
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 100)
        let bytes = descriptors.count * MemoryLayout<proc_fdinfo>.size
        let count = proc_pidinfo(launch[0], PROC_PIDLISTFDS, 0, &descriptors, Int32(bytes))
        XCTAssertGreaterThan(count, 0)
        XCTAssertFalse(descriptors.prefix(Int(count) / MemoryLayout<proc_fdinfo>.size).contains { $0.proc_fd == 7000 })
        XCTAssertEqual(kill(owner.processIdentifier, SIGKILL), 0)
        XCTAssertTrue(waitUntil(4, { !active(browser[0]) && !active(launch[0]) }))
    }

    func testAlreadyReapedGuardianRevokesSignalAuthorityEvenWithCachedExit() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let launched = try OwnedCommandProcess.spawnGuardedBrowser(executable: fixture.executable,
            arguments: ["browser", fixture.directory.path], environment: [:])
        defer { try? launched.browser.finishBrowser() }
        _ = try fixture.record("leaf")
        close(launched.lifetimeWriter)
        XCTAssertTrue(launched.guardian.waitForExitEvent(timeout: 4))
        _ = try launched.guardian.status()
        var status: Int32 = 0
        XCTAssertEqual(waitpid(launched.guardian.processIdentifier, &status, WNOHANG), launched.guardian.processIdentifier)
        for _ in 0..<2 {
            XCTAssertThrowsError(try launched.guardian.finishGuardian()) { error in
                guard case OwnedCommandProcess.Failure.system(let code) = error else { return XCTFail("unexpected \(error)") }
                XCTAssertEqual(code, ECHILD)
            }
        }
    }
}

private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    } while ContinuousClock.now < deadline
    return condition()
}

private func active(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status != UInt32(SZOMB)
}

private let fixtureSource = #"""
#include "VerdictUIProcessGuardian.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <poll.h>
extern char **environ;
static int marker = -1;
static void stalled_child(void) {
    char value[32]; int count = 31; value[count] = '\n';
    pid_t pid = getpid(); do { value[--count] = (char)('0' + pid % 10); pid /= 10; } while (pid);
    write(marker, value + count, (size_t)(32 - count)); close(marker);
    poll(NULL, 0, 750);
}
static void record(const char *root, const char *name, int a, int b, int c, int d) {
    char path[4096]; snprintf(path, sizeof(path), "%s/%s", root, name);
    FILE *file = fopen(path, "w"); if (!file) _exit(90);
    fprintf(file, "%d %d %d %d\n", a, b, c, d); fclose(file);
}
static int exists(const char *root, const char *name) {
    char path[4096]; snprintf(path, sizeof(path), "%s/%s", root, name);
    return access(path, F_OK) == 0;
}
int main(int argc, char **argv) {
    if (argc < 2) return 91;
    const char *mode = argv[1], *root = argc > 2 ? argv[2] : "";
    if (mode[0] == '-') {
        mode = "browser";
        for (int i = 1; i < argc; ++i)
            if (strncmp(argv[i], "--user-data-dir=", 16) == 0) root = argv[i] + 16;
    }
    if (!strcmp(mode, "sentinel")) { sleep(10); return 0; }
    if (!strcmp(mode, "browser")) {
        int clean = 1; struct sigaction action; sigset_t mask;
        sigprocmask(SIG_SETMASK, NULL, &mask);
        int signals[] = {SIGTERM, SIGINT, SIGPIPE, SIGUSR1};
        for (int i = 0; i < 4; ++i) {
            sigaction(signals[i], NULL, &action);
            if (action.sa_handler != SIG_DFL || sigismember(&mask, signals[i])) clean = 0;
        }
        record(root, "browser", getpid(), getpgrp(), fcntl(7000, F_GETFD) >= 0, clean);
        signal(SIGTERM, SIG_IGN);
        pid_t leaf = fork();
        if (leaf == 0) { record(root, "leaf", getpid(), getpgrp(), 0, 0); sleep(8); return 0; }
        for (int i = 0; i < 800 && !exists(root, "exit-browser"); ++i) usleep(10000);
        return 0;
    }
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGPIPE, SIG_IGN); signal(SIGUSR1, SIG_IGN);
    sigset_t blocked; sigemptyset(&blocked); sigaddset(&blocked, SIGUSR1); sigaddset(&blocked, SIGTERM);
    pthread_sigmask(SIG_SETMASK, &blocked, NULL);
    if (!strcmp(mode, "high-fd")) {
        int fd = open("/dev/null", O_RDONLY); if (dup2(fd, 7000) != 7000) return 92; close(fd);
        struct rlimit limit; getrlimit(RLIMIT_NOFILE, &limit); limit.rlim_cur = 64;
        if (setrlimit(RLIMIT_NOFILE, &limit)) return 93;
    }
    if (!strcmp(mode, "launch-death")) {
        char path[4096]; snprintf(path, sizeof(path), "%s/before-ready", root);
        marker = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        pthread_atfork(NULL, NULL, stalled_child);
    }
    char *args[] = {argv[0], "browser", (char *)root, NULL};
    vui_guardian_launch_result result;
    int error = vui_guardian_launch(argv[0], args, environ, 3000, 1000, &result);
    record(root, "launched", result.guardian_pid, result.browser_pid, result.group_ready, error ? error : result.error);
    if (error || result.error) return 94;
    if (!strcmp(mode, "leak")) {
        pid_t leaked = fork();
        if (leaked == 0) {
            record(root, "leaked", getpid(), getpgrp(), 0, 0);
            for (int i = 0; i < 800 && !exists(root, "release-leaked"); ++i) usleep(10000);
            return 0;
        }
    }
    sleep(10); close(result.lifetime_fd); return 0;
}
"""#
