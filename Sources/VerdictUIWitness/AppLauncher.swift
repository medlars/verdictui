import AppKit
import Foundation

/// Launch a fresh instance of an app with chosen arguments and environment,
/// read it, and terminate it (CIS-1DDD35B2, CIS-15F8D85E).
///
/// A RUNNING app cannot be re-themed or re-localised from outside, and it
/// cannot be told to show its empty state. What CAN be done from outside is to
/// start a new instance with launch arguments — `-AppleLanguages`,
/// `-AppleInterfaceStyle`, or an app-defined fixture flag — which is how a
/// sweep varies appearance and how a named data state is reached without
/// adopting probes.
///
/// Launched through LaunchServices (`NSWorkspace`), never fork/exec: a
/// fork/exec child is not published to the accessibility server (`no.md` #43).
/// Always a NEW instance, so an already-running copy is never read by mistake.
@MainActor
public enum AppLauncher {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notAnApp(String)
        case launchFailed(String)
        case neverReadable(String)

        public var description: String {
            switch self {
            case .notAnApp(let path): "\(path) is not an application bundle"
            case .launchFailed(let detail): "could not launch the app: \(detail)"
            case .neverReadable(let detail):
                "the launched app never published a readable surface: \(detail)"
            }
        }
    }

    /// Launch arguments that select a locale and an appearance.
    ///
    /// `nil` leaves the axis at the system setting. A locale such as `de_DE`
    /// sets both the language list and the region.
    public static func variantArguments(locale: String?, colorScheme: String?) -> [String] {
        var args: [String] = []
        if let locale {
            let language = locale.replacingOccurrences(of: "_", with: "-")
            args += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        }
        if let colorScheme {
            args += ["-AppleInterfaceStyle", colorScheme.lowercased() == "dark" ? "Dark" : "Light"]
        }
        return args
    }

    /// Launch `bundle` as a new instance and return its pid once `surface`
    /// reads, or throw after `timeout`.
    public static func launch(
        bundle: URL, arguments: [String], environment: [String: String],
        surface: AXReader.Surface, timeout: TimeInterval
    ) async throws -> pid_t {
        guard Bundle(url: bundle)?.bundleIdentifier != nil else {
            throw Failure.notAnApp(bundle.path)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        configuration.environment = environment
        configuration.activates = false
        configuration.addsToRecentItems = false
        let app: NSRunningApplication
        do {
            app = try await NSWorkspace.shared.openApplication(
                at: bundle, configuration: configuration)
        } catch {
            throw Failure.launchFailed(String(describing: error))
        }
        let pid = app.processIdentifier
        let deadline = Date().addingTimeInterval(timeout)
        var lastError = "no read attempted"
        while Date() < deadline {
            do {
                _ = try AXReader.readTree(pid: pid, surface: surface)
                return pid
            } catch let failure as AXReader.Failure {
                if failure == .notTrusted { terminate(pid: pid); throw failure }
                lastError = failure.description
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        terminate(pid: pid)
        throw Failure.neverReadable(lastError)
    }

    /// Terminate an instance this launcher started: politely, then by force.
    public static func terminate(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.terminate()
        let deadline = Date().addingTimeInterval(3)
        while !app.isTerminated, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if !app.isTerminated { app.forceTerminate() }
    }
}
