import Foundation
import VerdictUIKernel

/// Owned by the shared daemon handler, not individual CLI invocations. The
/// profile lock prevents a second daemon/session from borrowing the browser.
public actor WebSessionManager {
    private let root: URL
    private let invalidRootOverride: Bool
    private let environment: [String: String]
    private var sessions: [String: WebSession] = [:]
    private var opening: Set<String> = []
    private var launches: [String: Task<WebSession, Error>] = [:]
    private var stopping = false

    public init(root: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        let override = environment["VERDICTUI_WEB_PROFILE_ROOT"]
        invalidRootOverride = root == nil && override != nil && !(override?.hasPrefix("/") == true)
        self.root = root ?? override.map(URL.init(fileURLWithPath:)) ?? ProfileRegistry.defaultRoot()
        self.environment = environment
    }

    public func list() async -> [WebSessionInfo] {
        var result: [WebSessionInfo] = []
        for key in sessions.keys.sorted() {
            if let session = sessions[key] {
                if await session.isAvailable() { result.append(await session.info()) }
                else if sessions[key] === session { sessions.removeValue(forKey: key) }
            }
        }
        return result
    }

    /// Opening an already open identity navigates its owned warm browser. An
    /// identity held by a different manager/process is always refused by lock.
    public func open(profile: String, url: URL, width: Int = 1280, height: Int = 800) async throws -> WebSessionInfo {
        guard !invalidRootOverride else { throw WebBrowserError.invalidWebOperation(reason: "VERDICTUI_WEB_PROFILE_ROOT must be an absolute nonempty path") }
        guard !stopping else { throw WebBrowserError.invalidWebOperation(reason: "session manager is closing") }
        guard !opening.contains(profile) else { throw WebBrowserError.invalidWebOperation(reason: "profile is opening") }
        opening.insert(profile)
        defer { opening.remove(profile) }
        if let session = sessions[profile] {
            if await session.isAvailable() {
                try await session.navigate(url: url)
                return await session.info()
            }
            if sessions[profile] === session { sessions.removeValue(forKey: profile) }
        }
        let launch = Task { [root, environment] in
            try await WebSession.open(profile: profile, url: url, registry: ProfileRegistry(root: root),
                                      environment: environment, width: width, height: height)
        }
        launches[profile] = launch
        defer { launches.removeValue(forKey: profile) }
        let session = try await withTaskCancellationHandler {
            try await launch.value
        } onCancel: { launch.cancel() }
        guard !stopping else {
            try await session.close()
            throw WebBrowserError.invalidWebOperation(reason: "session manager closed while opening")
        }
        sessions[profile] = session
        return await session.info()
    }

    public func navigate(profile: String, url: URL) async throws {
        try await session(profile).navigate(url: url)
    }
    public func render(profile: String) async throws -> SemanticNode { try await session(profile).render() }
    public func verify(profile: String, expectText: String? = nil) async throws -> Verdict {
        try await session(profile).verify(expectText: expectText)
    }
    public func act(profile: String, action: WebAction, expectText: String? = nil) async throws -> Verdict {
        try await session(profile).act(action, expectText: expectText)
    }
    public func close(profile: String) async throws {
        guard let owned = sessions[profile] else { throw WebBrowserError.unknownSession(profile: profile) }
        try await owned.close()
        if sessions[profile] === owned { sessions.removeValue(forKey: profile) }
    }
    @discardableResult
    public func closeAll() async -> [WebBrowserError] {
        stopping = true
        var failures: [WebBrowserError] = []
        // Opening browsers are owned before they publish an endpoint. Await
        // cancellation cleanup before a signal handler may exit the daemon.
        let pending = launches
        pending.values.forEach { $0.cancel() }
        for launch in pending.values {
            do { try await launch.value.close() }
            catch let error as WebBrowserError {
                if case .processRefusedToDie = error { failures.append(error) }
            } catch { /* A cancelled launch has already awaited child cleanup. */ }
        }
        for profile in Array(sessions.keys) {
            do { try await close(profile: profile) }
            catch { failures.append(WebSession.sanitized(error)) }
        }
        return failures
    }
    private func session(_ profile: String) async throws -> WebSession {
        guard let session = sessions[profile] else { throw WebBrowserError.unknownSession(profile: profile) }
        guard await session.isAvailable() else {
            if sessions[profile] === session { sessions.removeValue(forKey: profile) }
            throw WebBrowserError.unknownSession(profile: profile)
        }
        return session
    }
}
