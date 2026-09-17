import Foundation

/// Why a web operation could not proceed.
///
/// Every case is a NAMED reason, never a bare string: the CLI layer (Wave 11
/// T4) turns these into exit 2 — "I could not produce a verdict" — and a
/// caller diffing two failures must be able to tell "no browser installed"
/// from "the profile is in use" without re-running anything. `Equatable` so
/// tests assert the exact case, `CustomStringConvertible` so a human reading
/// a log sees the channels that were searched rather than an enum tag.
public enum WebBrowserError: Error, Equatable, CustomStringConvertible {
    /// No Chromium-channel browser was found, and no override was set.
    ///
    /// Names every channel searched so the fix ("install Chrome" vs "the
    /// override points at a moved binary") is decidable from the message.
    case browserNotFound(channelsSearched: [String])
    /// The override (`VERDICTUI_WEB_BROWSER`) was set but does not name an
    /// executable file. Deliberately NOT a silent fall-through to the search
    /// table: an override that quietly loses to discovery would launch a
    /// different browser than the operator asked for, and nothing would
    /// report the substitution.
    case overrideNotExecutable(path: String)
    /// The profile's lock names a LIVE process. The acquisition did not
    /// proceed — this is the G4 refusal, not a wait: two sessions can never
    /// share one browser by construction.
    case profileInUse(profile: String, pid: pid_t)
    /// The browser process exited before publishing its DevTools endpoint.
    case launchFailed(reason: String)
    /// The browser stayed alive but never published a parseable
    /// `DevToolsActivePort` within the discovery deadline.
    case devtoolsNotDiscovered(profileDirectory: String, within: TimeInterval)
    /// The endpoint file parsed but the port is not a usable TCP port.
    case invalidDevtoolsPort(raw: String)
    /// The health probe did not answer 200. Carries the status the endpoint
    /// DID return, or nil for a transport-level failure.
    case healthProbeFailed(endpoint: String, status: Int?)
    /// The browser survived SIGTERM and SIGKILL — terminate refused to claim
    /// success it could not verify by pid liveness.
    case processRefusedToDie(pid: pid_t)
    /// The profile name would escape the registry root (path traversal, or a
    /// name that cannot be a single directory component).
    case invalidProfileName(name: String)
    /// The window-audit detector was asked to run where `CGWindowList` does
    /// not exist (iOS). Fail-closed: an audit that cannot run must never
    /// report zero windows.
    case windowAuditUnsupportedPlatform
    /// A lock file operation failed for a reason that is not "someone else
    /// holds it" — permissions, an unwritable parent, non-convergence.
    case lockIOFailure(path: String, reason: String)
    /// The WebSocket is closed or a socket operation failed. This is terminal.
    case cdpConnectionClosed(reason: String)
    /// The complete request (including its socket write) exceeded its deadline.
    case cdpRequestTimedOut(method: String)
    /// The caller cancelled its request before a reply arrived.
    case cdpRequestCancelled(method: String)
    /// CDP returned an error envelope for this request.
    case cdpError(code: Int, message: String)
    /// The socket delivered an invalid CDP envelope or a non-text frame.
    case invalidCDPResponse(reason: String)
    /// The endpoint, timeout, or parameters cannot form a valid request.
    case invalidCDPRequest(reason: String)

    public var description: String {
        switch self {
        case let .browserNotFound(channels):
            return "no Chromium-channel browser found; searched: \(channels.joined(separator: ", ")). Set VERDICTUI_WEB_BROWSER to an explicit path to override."
        case let .overrideNotExecutable(path):
            return "VERDICTUI_WEB_BROWSER override '\(path)' is not an executable file; refusing to fall back to the search table."
        case let .profileInUse(profile, pid):
            return "profile '\(profile)' is held by live pid \(pid); a second session cannot share one browser."
        case let .launchFailed(reason):
            return "browser exited during launch: \(reason)"
        case let .devtoolsNotDiscovered(dir, within):
            return "DevToolsActivePort never appeared in \(dir) within \(Int(within))s."
        case let .invalidDevtoolsPort(raw):
            return "DevToolsActivePort does not name a usable port: \(raw.prefix(80))"
        case let .healthProbeFailed(endpoint, status):
            return "health probe on \(endpoint) returned \(status.map(String.init) ?? "no HTTP status")."
        case let .processRefusedToDie(pid):
            return "browser pid \(pid) survived SIGTERM and SIGKILL; refusing to report it terminated."
        case let .invalidProfileName(name):
            return "profile name '\(name)' is not a single safe directory component."
        case .windowAuditUnsupportedPlatform:
            return "the CGWindowList window audit does not exist on this platform."
        case let .lockIOFailure(path, reason):
            return "lock file operation on '\(path)' failed: \(reason)"
        case let .cdpConnectionClosed(reason):
            return "CDP connection closed: \(reason)"
        case let .cdpRequestTimedOut(method):
            return "CDP request '\(method)' exceeded its deadline."
        case let .cdpRequestCancelled(method):
            return "CDP request '\(method)' was cancelled."
        case let .cdpError(code, message):
            return "CDP error \(code): \(message)"
        case let .invalidCDPResponse(reason):
            return "invalid CDP response: \(reason)"
        case let .invalidCDPRequest(reason):
            return "invalid CDP request: \(reason)"
        }
    }
}
