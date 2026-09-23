import Foundation
import VerdictUIKernel

/// Owned by the shared daemon handler, not individual CLI invocations. The
/// profile lock prevents a second daemon/session from borrowing the browser.
public actor WebSessionManager {
    private let root: URL
    private let environment: [String: String]
    private var sessions: [String: WebSession] = [:]
    private var opening: Set<String> = []
    private var stopping = false

    public init(root: URL = ProfileRegistry.defaultRoot(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.root = root; self.environment = environment
    }

    public func list() async -> [WebSessionInfo] {
        var result: [WebSessionInfo] = []
        for key in sessions.keys.sorted() {
            if let session = sessions[key] { result.append(await session.info()) }
        }
        return result
    }

    /// Opening an already open identity navigates its owned warm browser. An
    /// identity held by a different manager/process is always refused by lock.
    public func open(profile: String, url: URL, width: Int = 1280, height: Int = 800) async throws -> WebSessionInfo {
        guard !stopping else { throw WebBrowserError.invalidWebOperation(reason: "session manager is closing") }
        guard !opening.contains(profile) else { throw WebBrowserError.invalidWebOperation(reason: "profile is opening") }
        if let session = sessions[profile] {
            try await session.navigate(url: url)
            return await session.info()
        }
        opening.insert(profile)
        defer { opening.remove(profile) }
        let session = try await WebSession.open(profile: profile, url: url, registry: ProfileRegistry(root: root),
                                                environment: environment, width: width, height: height)
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
        let owned = try session(profile)
        try await owned.close()
        sessions.removeValue(forKey: profile)
    }
    @discardableResult
    public func closeAll() async -> [WebBrowserError] {
        stopping = true
        var failures: [WebBrowserError] = []
        for profile in Array(sessions.keys) {
            do { try await close(profile: profile) }
            catch { failures.append(WebSession.sanitized(error)) }
        }
        return failures
    }
    private func session(_ profile: String) throws -> WebSession {
        guard let session = sessions[profile] else { throw WebBrowserError.unknownSession(profile: profile) }
        return session
    }
}
