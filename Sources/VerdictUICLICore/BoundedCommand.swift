import Darwin
import Foundation

/// Owns one process group while retaining its unreaped leader as an identity
/// anchor. A completed leader cannot have its PID recycled before cleanup.
final class OwnedCommandProcess: @unchecked Sendable {
    enum Failure: Error { case invalidLaunch, system(Int32) }
    let processIdentifier: pid_t
    private let lock = NSLock()
    private var reaped = false
    private var exitCode: Int32?

    private init(pid: pid_t) { processIdentifier = pid }

    static func spawn(executable: URL, arguments: [String], directory: URL,
                      environment: [String: String], standardInput: Int32? = nil,
                      standardOutput: Int32? = nil, standardError: Int32? = nil) throws -> OwnedCommandProcess {
        let argv = [executable.path] + arguments
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        guard executable.isFileURL, directory.isFileURL,
              !(argv + env + [directory.path]).contains(where: { $0.contains("\0") }) else { throw Failure.invalidLaunch }
        var actions: posix_spawn_file_actions_t?
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        if #available(macOS 26.0, *) {
            try checked(posix_spawn_file_actions_addchdir(&actions, directory.path))
        } else {
            try checked(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        }
        for (source, destination) in [(standardInput, STDIN_FILENO), (standardOutput, STDOUT_FILENO), (standardError, STDERR_FILENO)] {
            if let source { try checked(posix_spawn_file_actions_adddup2(&actions, source, destination)) }
            else { try checked(posix_spawn_file_actions_addopen(&actions, destination, "/dev/null", O_RDWR, 0)) }
        }
        var attributes: posix_spawnattr_t?
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        var signals = sigset_t()
        sigemptyset(&signals)
        for number in [SIGTERM, SIGINT, SIGPIPE] { sigaddset(&signals, number) }
        try checked(posix_spawnattr_setsigdefault(&attributes, &signals))
        var mask = sigset_t()
        sigemptyset(&mask)
        try checked(posix_spawnattr_setsigmask(&attributes, &mask))
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        try checked(posix_spawnattr_setflags(&attributes, Int16(flags)))
        let argumentPointers = argv.map { strdup($0) }
        let environmentPointers = env.map { strdup($0) }
        defer { (argumentPointers + environmentPointers).forEach { free($0) } }
        guard argumentPointers.allSatisfy({ $0 != nil }), environmentPointers.allSatisfy({ $0 != nil }) else { throw Failure.system(ENOMEM) }
        var argumentVector = argumentPointers + [nil]
        var environmentVector = environmentPointers + [nil]
        var pid: pid_t = 0
        try checked(posix_spawn(&pid, executable.path, &actions, &attributes, &argumentVector, &environmentVector))
        return OwnedCommandProcess(pid: pid)
    }

    /// Nil means running; observing exit never reaps the identity anchor.
    func status() throws -> Int32? {
        lock.lock(); defer { lock.unlock() }
        return try observe()
    }

    @discardableResult
    func stop(grace: TimeInterval = 1) throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if reaped { return exitCode ?? 128 + SIGKILL }
        var observed = try observe()
        try signalGroup(SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, grace)
        while observed == nil && ProcessInfo.processInfo.systemUptime < deadline {
            usleep(20_000)
            observed = try observe()
        }
        // The leader is still unreaped, even if it already exited. Kill any
        // remaining descendants before releasing that unique group identity.
        try signalGroup(SIGKILL)
        var rawStatus: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(processIdentifier, &rawStatus, 0) } while result == -1 && errno == EINTR
        guard result == processIdentifier else { reaped = true; throw Failure.system(errno) }
        reaped = true
        let code = observed ?? ((rawStatus & 0x7f) == 0 ? (rawStatus >> 8) & 0xff : 128 + (rawStatus & 0x7f))
        exitCode = code
        return code
    }

    private func observe() throws -> Int32? {
        if reaped || exitCode != nil { return exitCode }
        var info = siginfo_t()
        var result: Int32
        repeat { result = waitid(P_PID, id_t(processIdentifier), &info, WEXITED | WNOHANG | WNOWAIT) } while result == -1 && errno == EINTR
        guard result == 0 else {
            // If another owner reaped the child, it is no longer safe to signal
            // this numeric process group. Refuse instead of guessing ownership.
            if errno == ECHILD { reaped = true }
            throw Failure.system(errno)
        }
        guard info.si_pid == processIdentifier else { return nil }
        exitCode = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
        return exitCode
    }

    private func signalGroup(_ number: Int32) throws {
        guard !reaped else { return }
        guard kill(-processIdentifier, number) != 0 else { return }
        let failure = errno
        if failure == ESRCH { return }
        // Darwin returns EPERM for a group containing only zombies, including
        // our deliberately unreaped anchor. Verify members before accepting it.
        if failure == EPERM && groupHasOnlyExitedMembers() { return }
        throw Failure.system(failure)
    }

    private func groupHasOnlyExitedMembers() -> Bool {
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(processIdentifier), nil, 0)
        guard bytes > 0 else { return false }
        var members = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 16)
        let capacity = Int32(members.count * MemoryLayout<pid_t>.size)
        let count = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(processIdentifier), &members, capacity)
        guard count > 0 && count < capacity else { return false }
        for member in members.prefix(Int(count) / MemoryLayout<pid_t>.size) where member > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let read = proc_pidinfo(member, PROC_PIDTBSDINFO, 0, &info, size)
            if read == 0 && errno == ESRCH { continue }
            guard read == size else { return false }
            if info.pbi_pgid == UInt32(processIdentifier) && info.pbi_status != UInt32(SZOMB) { return false }
        }
        return true
    }

    private static func checked(_ result: Int32) throws {
        guard result == 0 else { throw Failure.system(result) }
    }

    deinit { _ = try? stop(grace: 0) }
}

/// A subprocess boundary for project checks: no shell, bounded time and output.
enum BoundedCommand {
    struct Result: Sendable { let code: Int32; let output: Data }
    enum Failure: Error { case timeout, excessiveOutput, temporaryFile, invalidLimits }

    static func run(executable: URL, arguments: [String], root: URL,
                    timeout: TimeInterval = 330, limit: Int = 8 * 1_024 * 1_024) async throws -> Result {
        guard timeout.isFinite, timeout > 0, limit > 0 else { throw Failure.invalidLimits }
        let worker = Task.detached {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600]) else {
                throw Failure.temporaryFile
            }
            defer { try? FileManager.default.removeItem(at: file) }
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: ProjectRunner.delegationMarker)
            let process = try OwnedCommandProcess.spawn(executable: executable, arguments: arguments,
                directory: root, environment: environment, standardOutput: output.fileDescriptor)
            let deadline = ContinuousClock.now + .seconds(timeout)
            do {
                while try process.status() == nil {
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    if size > limit { throw Failure.excessiveOutput }
                    if ContinuousClock.now >= deadline { throw Failure.timeout }
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(20))
                }
                let code = try process.stop(grace: 0)
                try Task.checkCancellation()
                let data = try Data(contentsOf: file)
                guard data.count <= limit else { throw Failure.excessiveOutput }
                return Result(code: code, output: data)
            } catch {
                try process.stop()
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
