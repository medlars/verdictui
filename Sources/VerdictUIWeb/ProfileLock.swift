import Darwin
import Foundation

/// A kernel-held coordination lock plus an inspectable owner pidfile. The
/// persistent .guard inode must never be unlinked: flock then also arbitrates
/// the interval between pidfile creation and writing, including same-pid tasks.
/// The descriptor is close-on-exec so launched Chrome cannot inherit ownership.
public final class ProfileLock: @unchecked Sendable {
    public let path: URL
    public let lockHolderPid: pid_t
    private let mutex = NSLock()
    // Accessed only under mutex after construction. This is the sole mutable
    // state and justifies @unchecked Sendable for synchronous release/deinit.
    private var descriptor: Int32

    private init(path: URL, pid: pid_t, descriptor: Int32) {
        self.path = path; lockHolderPid = pid; self.descriptor = descriptor
    }

    public static func acquire(
        profile: String, registry: ProfileRegistry,
        liveness: @escaping @Sendable (pid_t) -> Bool = { ProcessLiveness.isAlive($0) }
    ) throws -> ProfileLock {
        try ProfileName.validate(profile)
        let path = registry.lockPath(for: profile)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let guardPath = path.appendingPathExtension("guard")
        let descriptor = open(guardPath.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw WebBrowserError.lockIOFailure(path: path.path, reason: "cannot open coordination lock")
        }
        var acquired = false
        defer { if !acquired { Darwin.close(descriptor) } }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw WebBrowserError.profileInUse(profile: profile, pid: readHolder(at: path) ?? -1)
        }
        // Compatibility with existing pidfiles and explicit liveness evidence:
        // a live legacy holder without a .guard is never stolen.
        if let holder = readHolder(at: path), liveness(holder) {
            throw WebBrowserError.profileInUse(profile: profile, pid: holder)
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        do {
            try Data("\(pid)\n".utf8).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            throw WebBrowserError.lockIOFailure(path: path.path, reason: "cannot write owner pid")
        }
        acquired = true
        return ProfileLock(path: path, pid: pid, descriptor: descriptor)
    }

    private static func readHolder(at path: URL) -> pid_t? {
        guard let text = try? String(contentsOf: path, encoding: .utf8),
            let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    /// Idempotent, including copies of the reference from asynchronous teardown.
    public func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard descriptor >= 0 else { return }
        if Self.readHolder(at: path) == lockHolderPid {
            // A missing pidfile is already released. Other errors leave the
            // live-pid marker in place, which fails closed on the next acquire.
            try? FileManager.default.removeItem(at: path)
        }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
