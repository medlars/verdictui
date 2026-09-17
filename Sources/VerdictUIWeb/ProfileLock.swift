import Darwin
import Foundation

/// A pidfile lock arbitrating which session owns a web profile.
///
/// The exclusive-create flag is the whole mechanism: two acquirers race on
/// one `open(2)` and exactly one wins. On a loss, the file's pid is read and
/// liveness-checked with `kill(pid, 0)` — and ONLY that primitive. The
/// framework registry lookups report DEREGISTRATION, not death (`no.md`
/// #82), so a lock keyed on a registry read would be stolen while its holder
/// runs.
///
/// ### The two-sided rule (spec exit gate 3)
///
/// A crashed run's lock (dead pid) is stolen; a live holder's lock is never
/// stolen. Both directions are asserted by tests, with the liveness
/// predicate INJECTED so the dead/live cases are deterministic — the kernel
/// cannot be asked to produce a dead pid of a known shape on demand, and a
/// guard whose two sides cannot both be exercised is not a guard.
public struct ProfileLock {
    /// Where the pidfile lives.
    public let path: URL
    /// The pid written into the pidfile (ours on a fresh acquire).
    public let lockHolderPid: pid_t
    let liveness: @Sendable (pid_t) -> Bool

    /// Acquire the lock for `profile`, stealing a dead holder's lock.
    ///
    /// Throws ``WebBrowserError/profileInUse(profile:pid:)`` when a live
    /// process holds the profile — the G4 refusal: the second session does
    /// not proceed, rather than sharing.
    public static func acquire(
        profile: String,
        registry: ProfileRegistry,
        liveness: @escaping @Sendable (pid_t) -> Bool = { ProcessLiveness.isAlive($0) }
    ) throws -> ProfileLock {
        try ProfileName.validate(profile)
        try ensureLocksDirectory(of: registry)
        let lockPath = registry.lockPath(for: profile)
        for _ in 0..<8 {
            if let lock = try createLockFile(profile: profile, at: lockPath) {
                return lock
            }
            // Lost the exclusive-create race. Read the holder; a live one
            // refuses the acquire, a dead or unreadable one is a crashed
            // run's lock and gets stolen.
            let holder = readHolderPid(at: lockPath)
            if let holder, liveness(holder) {
                throw WebBrowserError.profileInUse(profile: profile, pid: holder)
            }
            try? FileManager.default.removeItem(at: lockPath)
        }
        throw WebBrowserError.lockIOFailure(
            path: lockPath.path,
            reason: "acquisition did not converge within 8 exclusive-create attempts")
    }

    /// Try one exclusive create, writing and verifying our pid.
    ///
    /// Returns nil when the file already exists (the caller then reads the
    /// holder). Throws when the create succeeded but ownership could not be
    /// established — the write-then-verify readback caught a thief that
    /// unlinked our just-created file and created its own before our write
    /// landed in it. That thief now provably holds the lock, so the honest
    /// answer is the G4 refusal, not a retry.
    private static func createLockFile(profile: String, at path: URL) throws -> ProfileLock? {
        let fd = open(path.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd != -1 else { return nil }
        defer { close(fd) }
        let myPid = ProcessInfo.processInfo.processIdentifier
        let payload = Data("\(myPid)\n".utf8)
        let written = payload.withUnsafeBytes { buf -> Int in
            write(fd, buf.baseAddress, buf.count)
        }
        guard written == payload.count else {
            throw WebBrowserError.lockIOFailure(
                path: path.path, reason: "could not write the holder pid")
        }
        // Write-then-verify: re-read and require our own pid back.
        let readback = readHolderPid(at: path, retries: 1)
        guard readback == myPid else {
            throw WebBrowserError.profileInUse(
                profile: profile, pid: readback ?? -1)
        }
        return ProfileLock(
            path: path, lockHolderPid: myPid, liveness: { ProcessLiveness.isAlive($0) })
    }

    /// The pid in the pidfile, or nil when unreadable or non-numeric.
    ///
    /// An empty or garbage file is a crashed run's artifact and reads as nil
    /// (stealable); a MISSING file reads as nil after its retries, and the
    /// caller's next exclusive create may then win outright. Non-numeric
    /// content never becomes numeric, so it returns immediately rather than
    /// burning the retries.
    private static func readHolderPid(at path: URL, retries: Int = 3) -> pid_t? {
        for _ in 0..<max(1, retries) {
            if let text = try? String(contentsOf: path, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return pid_t(trimmed)
            }
        }
        return nil
    }

    /// Release the lock, but only if it still names us.
    ///
    /// If the content names another pid, a successor holds the file and we
    /// must not delete it — deleting a successor's lock would hand the
    /// profile to a third session while the second still runs.
    public func release() {
        let current = Self.readHolderPid(at: path, retries: 1)
        guard current == lockHolderPid else { return }
        try? FileManager.default.removeItem(at: path)
    }

    /// Create `<root>/locks/` so the exclusive create has somewhere to land.
    private static func ensureLocksDirectory(of registry: ProfileRegistry) throws {
        let locks = registry.root.appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: locks, withIntermediateDirectories: true)
    }
}
