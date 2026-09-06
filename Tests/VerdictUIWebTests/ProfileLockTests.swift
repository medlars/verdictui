import XCTest

@testable import VerdictUIWeb

/// The two-sided lock rule with INJECTED liveness, so the dead and live
/// cases are deterministic: a crashed run's lock is stolen; a live holder's
/// lock is never stolen. Both directions asserted (spec exit gate 3), plus
/// the in-process concurrency matrix (exit gate 2).
final class ProfileLockTests: XCTestCase {
    private func tempRegistry() -> ProfileRegistry {
        ProfileRegistry(
            root: URL(fileURLWithPath: NSTemporaryDirectory() + "vui-t1-\(UUID().uuidString)"))
    }

    func testAFreshAcquireWritesOurPid() throws {
        let registry = tempRegistry()
        defer { try? FileManager.default.removeItem(at: registry.root) }
        let lock = try ProfileLock.acquire(profile: "work", registry: registry)
        XCTAssertEqual(
            lock.lockHolderPid,
            ProcessInfo.processInfo.processIdentifier)
        let content = try String(
            contentsOf: registry.lockPath(for: "work"), encoding: .utf8)
        XCTAssertEqual(
            content.trimmingCharacters(in: .whitespacesAndNewlines),
            String(ProcessInfo.processInfo.processIdentifier))
    }

    /// Exit gate 2, same-profile half: the second acquire does NOT proceed —
    /// the G4 refusal, in-process, with the live holder's pid named.
    func testASecondAcquireOnOneProfileRefuses() throws {
        let registry = tempRegistry()
        defer { try? FileManager.default.removeItem(at: registry.root) }
        _ = try ProfileLock.acquire(profile: "work", registry: registry)
        XCTAssertThrowsError(
            try ProfileLock.acquire(profile: "work", registry: registry)
        ) { error in
            guard case WebBrowserError.profileInUse(let name, let pid) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(name, "work")
            XCTAssertEqual(pid, ProcessInfo.processInfo.processIdentifier)
        }
        // The lock survives the refusal — the holder still holds it.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: registry.lockPath(for: "work").path))
    }

    /// Exit gate 2, distinct-profile half: both proceed.
    func testDistinctProfilesBothProceed() throws {
        let registry = tempRegistry()
        defer { try? FileManager.default.removeItem(at: registry.root) }
        let a = try ProfileLock.acquire(profile: "identity-a", registry: registry)
        let b = try ProfileLock.acquire(profile: "identity-b", registry: registry)
        XCTAssertEqual(a.lockHolderPid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(b.lockHolderPid, ProcessInfo.processInfo.processIdentifier)
        a.release()
        b.release()
    }

    /// Exit gate 3, dead direction: a crashed run's lock (dead pid) is
    /// stolen and the acquire proceeds.
    func testACrashedRunsLockIsStolen() throws {
        let registry = tempRegistry()
        defer { try? FileManager.default.removeItem(at: registry.root) }
        let lockPath = registry.lockPath(for: "work")
        try FileManager.default.createDirectory(
            at: lockPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "424242\n".write(to: lockPath, atomically: true, encoding: .utf8)
        let lock = try ProfileLock.acquire(
            profile: "work", registry: registry,
            liveness: { pid in pid != 424242 })
        XCTAssertEqual(lock.lockHolderPid, ProcessInfo.processInfo.processIdentifier)
        let content = try String(contentsOf: lockPath, encoding: .utf8)
        XCTAssertEqual(
            content.trimmingCharacters(in: .whitespacesAndNewlines),
            String(ProcessInfo.processInfo.processIdentifier))
    }

    /// Exit gate 3, live direction: a live holder's lock is NEVER stolen.
    /// Injected liveness makes "live" deterministic; the test also asserts
    /// the file still exists and still names the live holder afterwards.
    func testALiveHoldersLockIsNeverStolen() throws {
        let registry = tempRegistry()
        defer { try? FileManager.default.removeItem(at: registry.root) }
        let lockPath = registry.lockPath(for: "work")
        try FileManager.default.createDirectory(
            at: lockPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "99999\n".write(to: lockPath, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try ProfileLock.acquire(
                profile: "work", registry: registry,
                liveness: { pid in pid == 99999 })
        ) { error in
            guard case WebBrowserError.profileInUse(let name, let pid) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(name, "work")
            XCTAssertEqual(pid, 99999)
        }
        let content = try String(contentsOf: lockPath, encoding: .utf8)
        XCTAssertEqual(
            content.trimmingCharacters(in: .whitespacesAndNewlines), "99999")
    }
}
