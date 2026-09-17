import Darwin
import Foundation

/// The one liveness primitive every consumer of this target uses.
///
/// `kill(pid, 0)` — signal 0 carries no payload; the kernel answers about the
/// process's existence and nothing else. `ESRCH` means the process does not
/// exist; `EPERM` means it exists but is owned by someone else, which is
/// ALIVE for this purpose (a lock naming a root-owned pid is held, not free).
///
/// ### Why this and never a framework registry
///
/// `NSRunningApplication` stops resolving when an app DEREGISTERS from
/// LaunchServices, which is not process death — measured 2026-08-25
/// (`no.md` #82): the same host read as dead by `NSRunningApplication == nil`
/// at 3.5–9.6 s while `kill -0` showed it alive at 21.7 s. A lock keyed on a
/// registry read would be stolen while its holder runs. The framework lookup
/// is also unavailable off-macOS, while `kill` is POSIX.
public enum ProcessLiveness {
    /// Whether the process named by `pid` exists right now.
    ///
    /// A reused pid can make a DEAD holder read alive — the standard pidfile
    /// false-positive, accepted here because the registry also stores the
    /// holder's start identity would be a second mechanism to keep in step.
    /// Deliberately narrow: this answers EXISTENCE, never identity.
    public static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
