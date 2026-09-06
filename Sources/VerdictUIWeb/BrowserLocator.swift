import Foundation

/// Where to find the browser, decided once per call from primary evidence.
///
/// Resolution order, per the Wave 11 spec: an explicit override wins, then
/// the search table (Google Chrome stable, then Chromium — the standard macOS
/// install paths). An override that does not resolve is a typed error rather
/// than a silent fallback: an override that quietly loses to discovery would
/// launch a different browser than the operator asked for, and nothing would
/// report the substitution.
///
/// Measured on this machine 2026-09-02: Google Chrome stable 152.0.7977.65
/// present at the standard path; no Chromium.app installed.
public enum BrowserLocator {
    /// Environment key holding an explicit browser executable path.
    public static let overrideEnvironmentKey = "VERDICTUI_WEB_BROWSER"

    /// One candidate browser and the path it installs at.
    public struct Channel {
        public let name: String
        public let path: String
        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    /// The search table, in priority order: Google Chrome stable, then
    /// Chromium — the standard macOS install paths.
    public static let candidateChannels: [Channel] = [
        Channel(
            name: "Google Chrome stable",
            path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        Channel(
            name: "Chromium",
            path: "/Applications/Chromium.app/Contents/MacOS/Chromium"),
    ]

    /// Locate the browser, or fail closed with a named reason.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        channels: [Channel] = candidateChannels,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) throws -> URL {
        if let override = environment[Self.overrideEnvironmentKey] {
            guard fileExists(override) else {
                throw WebBrowserError.overrideNotExecutable(path: override)
            }
            return URL(fileURLWithPath: override)
        }
        var searched: [String] = []
        for channel in channels {
            searched.append(channel.name)
            if fileExists(channel.path) {
                return URL(fileURLWithPath: channel.path)
            }
        }
        throw WebBrowserError.browserNotFound(channelsSearched: searched)
    }
}
