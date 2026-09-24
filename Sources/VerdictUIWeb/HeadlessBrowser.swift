import Darwin
import Foundation

/// One headless browser session: launch, discover, probe, terminate.
///
/// ### Why owned process spawning and not LaunchServices (`open`)
///
/// The witness host needs LaunchServices because AX requires GUI
/// registration; the browser needs the OPPOSITE — headless Chrome must not
/// join the GUI session (the spec's G3 invisibility bar). A C-only guardian
/// owns its process group and survives a native host crash long enough to clean it.
///
/// ### Measured facts this design encodes (2026-09-02, Chrome stable
/// 152.0.7977.65 / macOS)
///
/// - `--headless=new --remote-debugging-port=0` writes `DevToolsActivePort`
///   (port, then browser WS path) into the user-data-dir within ~4 s of
///   start, and the file PERSISTS after death — so it is only ever read
///   inside the launch loop.
/// - SIGTERM alone terminates the browser in ~5.1 s — a real grace window,
///   so terminate() polls liveness for the grace, then escalates.
/// - The endpoint's `/json/version` answers 200 with a JSON body naming the
///   browser build.
public actor HeadlessBrowser {
    /// The browser's main process id.
    public let pid: pid_t
    /// The endpoint discovered from the DevToolsActivePort file.
    public let endpoint: DevtoolsEndpoint
    /// The user-data-dir this session's browser uses.
    public let profileDirectory: URL

    private let process: any BrowserProcessIdentity

    func isRunning() -> Bool { process.isRunning }

    /// Internal seam for deterministic lifecycle tests. Production identities
    /// can only come from launch(), which retains the guardian child.
    init(process: any BrowserProcessIdentity, endpoint: DevtoolsEndpoint, profileDirectory: URL) {
        self.process = process
        pid = process.pid
        self.endpoint = endpoint
        self.profileDirectory = profileDirectory
    }

    /// Launch-time knobs; every field has a measured default.
    public struct Options {
        /// Browser executable to spawn (BrowserLocator output).
        public let browser: URL
        /// The user-data-dir for this session (ProfileRegistry output).
        public let profileDirectory: URL
        /// How long to wait for DevToolsActivePort before giving up.
        public let discoveryTimeout: TimeInterval

        public init(
            browser: URL,
            profileDirectory: URL,
            discoveryTimeout: TimeInterval = 20
        ) {
            self.browser = browser
            self.profileDirectory = profileDirectory
            self.discoveryTimeout = discoveryTimeout
        }
    }

    /// Spawn the browser and wait for its DevTools endpoint.
    ///
    /// Static + async: the spawn itself is synchronous, but the discovery
    /// wait must yield cooperatively, so the entry point is async even
    /// though the owned spawn is not.
    public static func launch(_ options: Options) async throws -> HeadlessBrowser {
        guard FileManager.default.isExecutableFile(atPath: options.browser.path) else {
            throw WebBrowserError.launchFailed(
                reason: "no executable browser at \(options.browser.path)")
        }
        try FileManager.default.createDirectory(
            at: options.profileDirectory, withIntermediateDirectories: true)
        // A persisted DevToolsActivePort names the previous browser. Reading it
        // on a relaunch can attach to an unrelated process that reused its port.
        let activePort = options.profileDirectory.appendingPathComponent("DevToolsActivePort")
        if FileManager.default.fileExists(atPath: activePort.path) {
            try FileManager.default.removeItem(at: activePort)
        }
        let owned: LaunchedBrowserProcess
        do {
            owned = try LaunchedBrowserProcess.launch(executable: options.browser,
                arguments: Self.launchArguments(profileDirectory: options.profileDirectory),
                environment: ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("VERDICTUI_WEB_CRED_") })
        } catch {
            throw WebBrowserError.launchFailed(
                reason: "spawn failed: \(error)")
        }
        do {
            let deadline = ContinuousClock.now + .seconds(options.discoveryTimeout)
            while true {
                try Task.checkCancellation()
                if let endpoint = DevtoolsEndpoint.read(in: options.profileDirectory) {
                    return HeadlessBrowser(process: owned, endpoint: endpoint,
                                           profileDirectory: options.profileDirectory)
                }
                guard owned.isRunning else {
                    throw WebBrowserError.launchFailed(reason: "browser died before publishing its endpoint")
                }
                guard ContinuousClock.now < deadline else {
                    throw WebBrowserError.devtoolsNotDiscovered(
                        profileDirectory: options.profileDirectory.path, within: options.discoveryTimeout)
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            try owned.signal(SIGKILL)
            guard await awaitOwnedDeath(process: owned, within: 5) else {
                throw WebBrowserError.processRefusedToDie(pid: owned.pid)
            }
            try owned.finish()
            throw error
        }
    }

    /// The argv handed to the browser. Every flag is measured, not guessed:
    ///
    /// - `--headless=new`: the mode whose CGWindowList entries are never
    ///   composited (ONSCREEN=0 measured across every flag permutation).
    /// - `--remote-debugging-port=0`: ephemeral port, discovered from the
    ///   DevToolsActivePort file rather than guessed.
    /// - `--window-position=-32000,-32000`: belt-and-braces — bounds land
    ///   at −32000 even though the windows are already never composited.
    /// - `about:blank`: a page to load, so the browser reaches a settled
    ///   state rather than sitting on a session-restore prompt.
    public static func launchArguments(profileDirectory: URL) -> [String] {
        [
            "--headless=new",
            "--remote-debugging-port=0",
            "--user-data-dir=\(profileDirectory.path)",
            "--window-position=-32000,-32000",
            "about:blank",
        ]
    }

    /// What the health probe observed, as evidence rather than a bare bool.
    public struct HealthReport: Equatable, Sendable {
        /// The HTTP status the endpoint answered with.
        public let status: Int
        /// The `Browser` field of `/json/version`, when it parsed.
        public let browser: String?
    }

    /// GET `<origin>/json/version`, expecting 200.
    ///
    /// Explicit timeouts on both the request and the session (the fleet
    /// http-timeout rule: the default is a slow-motion outage). The session
    /// is invalidated after the single request so nothing outlives the call.
    public func healthProbe(timeout: TimeInterval = 5) async throws -> HealthReport {
        guard let url = URL(string: "\(endpoint.httpOrigin)/json/version") else {
            throw WebBrowserError.healthProbeFailed(endpoint: endpoint.httpOrigin, status: nil)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WebBrowserError.healthProbeFailed(endpoint: endpoint.httpOrigin, status: nil)
            }
            guard http.statusCode == 200 else {
                throw WebBrowserError.healthProbeFailed(
                    endpoint: endpoint.httpOrigin, status: http.statusCode)
            }
            return HealthReport(
                status: http.statusCode, browser: Self.browserField(from: data))
        } catch let error as WebBrowserError {
            throw error
        } catch {
            throw Self.wrapHealthTransport(error, origin: endpoint.httpOrigin)
        }
    }

    /// Wrap transport errors into the typed error with the endpoint named.
    private static func wrapHealthTransport(_ error: Error, origin: String) -> WebBrowserError {
        if let web = error as? WebBrowserError { return web }
        return .healthProbeFailed(endpoint: origin, status: nil)
    }

    /// The `Browser` field from the probe response BODY, or nil.
    static func browserField(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["Browser"] as? String
    }

    /// Poll liveness until death, bounded.
    static func awaitDeath(pid: pid_t, within grace: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(grace)
        while ContinuousClock.now < deadline {
            if !ProcessLiveness.isAlive(pid) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !ProcessLiveness.isAlive(pid)
    }

    /// Graceful-then-kill, tied to the retained guardian, never the browser PID.
    public func terminate(grace: TimeInterval = 10) async throws {
        guard process.isRunning else { try process.finish(); return }
        try process.signal(SIGTERM)
        if await Self.awaitOwnedDeath(process: process, within: grace) { try process.finish(); return }
        try process.signal(SIGKILL)
        if await Self.awaitOwnedDeath(process: process, within: 5) { try process.finish(); return }
        throw WebBrowserError.processRefusedToDie(pid: pid)
    }

    private static func awaitOwnedDeath(process: any BrowserProcessIdentity, within grace: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(grace)
        while ContinuousClock.now < deadline {
            if !process.isRunning { return true }
            // Cleanup must continue under caller cancellation. A cancelled
            // Task.sleep would return immediately and spin until the deadline.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
        }
        return !process.isRunning
    }

    /// A dead child's retained identity stays dead even when its pid is reused.
    deinit {
        if process.isRunning { try? process.signal(SIGKILL) }
        try? process.finish()
    }
}
