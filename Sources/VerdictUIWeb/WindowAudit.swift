import Foundation

/// The window server's account of a pid's windows, read from OUTSIDE the
/// audited process.
///
/// Reading from INSIDE the subject lies (no.md #50: a self-read of a shell
/// process returns nothing in either state), so the audit is always asked
/// about ANOTHER pid — the browser's — from the test or session process.
/// This is the invisibility gate (spec G3): a headless browser must present
/// zero ON-SCREEN windows.
///
/// ### Why ON-SCREEN, not ALL
///
/// MEASURED 2026-09-02, Chrome 152 headless=new: the browser pid owns 5
/// CGWindowList entries (rendering surfaces) but ONSCREEN=0 in every flag
/// permutation measured — the windows are never composited to any display.
/// "Zero ALL entries" is unsatisfiable on this channel; "zero composited
/// windows" is the property the user experiences and the bar this gate
/// holds. Reported alongside ALL as evidence.
#if os(macOS)
import CoreGraphics

public enum WindowAudit {
    /// Windows the window server is COMPOSITING for `pid`.
    public static func onScreenWindowCount(forPID pid: pid_t) throws -> Int {
        try audit(options: [.optionOnScreenOnly], pid: pid)
    }

    /// Every window object for `pid`, composited or not (evidence only).
    public static func allWindowCount(forPID pid: pid_t) throws -> Int {
        try audit(options: [.optionAll], pid: pid)
    }

    /// The shared read: filter the window server's list by owner pid.
    private static func audit(options: CGWindowListOption, pid: pid_t) throws -> Int {
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }.count
    }
}
#else

/// iOS: no CGWindowList. Fail-closed — an audit that cannot run must never
/// report zero windows, which is what returning 0 would claim.
public enum WindowAudit {
    public static func onScreenWindowCount(forPID pid: pid_t) throws -> Int {
        throw WebBrowserError.windowAuditUnsupportedPlatform
    }

    public static func allWindowCount(forPID pid: pid_t) throws -> Int {
        throw WebBrowserError.windowAuditUnsupportedPlatform
    }
}
#endif
