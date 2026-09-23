import Darwin
import Foundation

/// One headless browser session: launch, discover, probe, terminate.
///
/// ### Why fork/exec and not LaunchServices (`open`)
///
/// The witness host needs LaunchServices because AX requires GUI
/// registration; the browser needs the OPPOSITE — headless Chrome must not
/// join the GUI session (the spec's G3 invisibility bar). Plain `Process`
/// fork/exec is what Playwright uses for the same reason.
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

    /// Internal seam for deterministic lifecycle tests. Production identities
    /// can only come from launch(), which retains the exact Foundation child.
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
    /// though `Process.run()` is not.
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
        let process = Process()
        process.executableURL = options.browser
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("VERDICTUI_WEB_CRED_") }
        process.arguments = Self.launchArguments(profileDirectory: options.profileDirectory)
        // Browser diagnostics may echo page URLs or console messages. No
        // browser output is retained when a session can contain credentials.
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw WebBrowserError.launchFailed(
                reason: "spawn failed: \(error)")
        }
        let owned = LaunchedBrowserProcess(process: process)
        var handedOff = false
        defer { if !handedOff { owned.signal(SIGKILL) } }
        let deadline = ContinuousClock.now
            + .seconds(options.discoveryTimeout)
        while true {
            try Task.checkCancellation()
            if let endpoint = DevtoolsEndpoint.read(in: options.profileDirectory) {
                handedOff = true
                return HeadlessBrowser(
                    process: owned,
                    endpoint: endpoint,
                    profileDirectory: options.profileDirectory)
            }
            guard owned.isRunning else {
                throw WebBrowserError.launchFailed(
                    reason: "browser died before publishing its endpoint")
            }
            guard ContinuousClock.now < deadline else {
                owned.signal(SIGKILL)
                throw WebBrowserError.devtoolsNotDiscovered(
                    profileDirectory: options.profileDirectory.path,
                    within: options.discoveryTimeout)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
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

    /// Graceful-then-kill, tied to the original Process object. A later process
    /// that reuses its PID never becomes this session's child.
    public func terminate(grace: TimeInterval = 10) async throws {
        guard process.isRunning else { return }
        process.signal(SIGTERM)
        if await awaitOwnedDeath(within: grace) { return }
        process.signal(SIGKILL)
        if await awaitOwnedDeath(within: 5) { return }
        throw WebBrowserError.processRefusedToDie(pid: pid)
    }

    private func awaitOwnedDeath(within grace: TimeInterval) async -> Bool {
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
        if process.isRunning { process.signal(SIGKILL) }
    }
}
