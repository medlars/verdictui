import Foundation
import VerdictUIKernel

/// Owned by the shared daemon handler, not individual CLI invocations. The
/// profile lock prevents a second daemon/session from borrowing the browser.
public actor WebSessionManager {
    typealias Opener = @Sendable (String, URL, URL, [String: String], Int, Int) async throws -> WebSession
    private struct CloseOutcome: Sendable {
        let profile: String
        let session: WebSession?
        let failure: WebBrowserError?
    }
    private let root: URL
    private let invalidRootOverride: Bool
    private let environment: [String: String]
    private var sessions: [String: WebSession] = [:]
    private var opening: Set<String> = []
    private var launches: [String: Task<WebSession, Error>] = [:]
    private var stopping = false
    private var closingTask: Task<[CloseOutcome], Never>?
    private let opener: Opener

    public init(root: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        let override = environment["VERDICTUI_WEB_PROFILE_ROOT"]
        invalidRootOverride = root == nil && override != nil && !(override?.hasPrefix("/") == true)
        self.root = root ?? override.map(URL.init(fileURLWithPath:)) ?? ProfileRegistry.defaultRoot()
        self.environment = environment
        opener = { profile, url, root, environment, width, height in
            try await WebSession.open(profile: profile, url: url, registry: ProfileRegistry(root: root),
                                      environment: environment, width: width, height: height)
        }
    }

    /// Internal lifecycle seam; production always uses the real browser opener.
    init(root: URL, opener: @escaping Opener) {
        self.root = root; environment = [:]; invalidRootOverride = false; self.opener = opener
    }

    public func list() async -> [WebSessionInfo] {
        var result: [WebSessionInfo] = []
        for key in sessions.keys.sorted() {
            if let session = sessions[key] {
                do {
                    if try await session.isAvailable() { result.append(await session.info()) }
                    else if sessions[key] === session { sessions.removeValue(forKey: key) }
                } catch {
                    // Listing exposes available sessions only. A failed retirement
                    // remains owned here so closeAll can retry its cleanup.
                    continue
                }
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
            if try await session.isAvailable() {
                guard !stopping else { throw WebBrowserError.invalidWebOperation(reason: "session manager is closing") }
                try await session.navigate(url: url)
                let info = await session.info()
                guard !stopping else { throw WebBrowserError.invalidWebOperation(reason: "session manager is closing") }
                return info
            }
            if sessions[profile] === session { sessions.removeValue(forKey: profile) }
        }
        guard !stopping else { throw WebBrowserError.invalidWebOperation(reason: "session manager is closing") }
        let launch = Task { [root, environment, opener] in
            try await opener(profile, url, root, environment, width, height)
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
        let info = await session.info()
        guard !stopping else { throw WebBrowserError.invalidWebOperation(reason: "session manager is closing") }
        return info
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
        if let closingTask { return await closingTask.value.compactMap(\.failure) }
        stopping = true
        // Opening browsers are owned before they publish an endpoint. Await
        // cancellation cleanup before a signal handler may exit the daemon.
        let pending = launches
        let existing = sessions
        pending.values.forEach { $0.cancel() }
        // Start BOTH sets together. Serial batches multiply valid per-session
        // flush deadlines and let a slow launch delay already open profiles.
        let task = Task {
            await withTaskGroup(of: CloseOutcome.self) { group in
                for (profile, launch) in pending {
                    group.addTask {
                        let session: WebSession
                        do { session = try await launch.value }
                        catch let error as WebBrowserError {
                            if case .processRefusedToDie = error {
                                return CloseOutcome(profile: profile, session: nil, failure: error)
                            }
                            return CloseOutcome(profile: profile, session: nil, failure: nil)
                        } catch { return CloseOutcome(profile: profile, session: nil, failure: nil) }
                        return await Self.closeOutcome(profile: profile, session: session)
                    }
                }
                for (profile, session) in existing {
                    group.addTask { await Self.closeOutcome(profile: profile, session: session) }
                }
                var result: [CloseOutcome] = []
                for await outcome in group { result.append(outcome) }
                return result
            }
        }
        closingTask = task
        let outcomes = await task.value
        for outcome in outcomes {
            guard let session = outcome.session else { continue }
            if outcome.failure == nil, sessions[outcome.profile] === session {
                sessions.removeValue(forKey: outcome.profile)
            } else if outcome.failure != nil, sessions[outcome.profile] == nil {
                sessions[outcome.profile] = session
            }
        }
        closingTask = nil
        return outcomes.compactMap(\.failure)
    }

    private static func closeOutcome(profile: String, session: WebSession) async -> CloseOutcome {
        do {
            try await session.close()
            return CloseOutcome(profile: profile, session: session, failure: nil)
        } catch { return CloseOutcome(profile: profile, session: session, failure: WebSession.sanitized(error)) }
    }
    private func session(_ profile: String) async throws -> WebSession {
        guard let session = sessions[profile] else { throw WebBrowserError.unknownSession(profile: profile) }
        guard try await session.isAvailable() else {
            if sessions[profile] === session { sessions.removeValue(forKey: profile) }
            throw WebBrowserError.unknownSession(profile: profile)
        }
        return session
    }
}
