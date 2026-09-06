import Foundation

/// The DevTools endpoint a launched browser publishes for CDP clients.
///
/// Source of truth is the `DevToolsActivePort` file the browser writes into
/// its `--user-data-dir`. MEASURED 2026-09-02 on Google Chrome stable
/// 152.0.7977.65 / macOS: `--headless=new --remote-debugging-port=0` writes
/// a two-line file (port, then the browser WS path) AND prints
/// `DevTools listening on ws://127.0.0.1:<port>/devtools/browser/<id>` to
/// stderr. The file is the parseable contract; stderr is the fallback only
/// on the failure path (the launch error carries its excerpt).
public struct DevtoolsEndpoint: Equatable, Sendable {
    /// The TCP port DevTools bound.
    public let port: Int
    /// The browser-scoped WebSocket path, e.g. `/devtools/browser/<uuid>`.
    public let browserPath: String

    public init(port: Int, browserPath: String) {
        self.port = port
        self.browserPath = browserPath
    }

    /// The HTTP origin the DevTools server answers on.
    public var httpOrigin: String { "http://127.0.0.1:\(port)" }

    /// The browser-level WebSocket URL a CDP transport connects to (T2).
    public var websocketURL: String { "ws://127.0.0.1:\(port)\(browserPath)" }

    /// Parse the file's content: line 1 = port, line 2 = browser path.
    public static func parse(_ text: String) throws -> DevtoolsEndpoint {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let portLine = lines.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard let port = Int(portLine), (1...65535).contains(port) else {
            throw WebBrowserError.invalidDevtoolsPort(raw: text)
        }
        let pathLine = lines.count > 1
            ? lines[1].trimmingCharacters(in: .whitespaces)
            : ""
        return DevtoolsEndpoint(port: port, browserPath: pathLine)
    }

    /// Read + parse the endpoint file in a profile directory.
    ///
    /// Returns nil when the file does not exist yet (the launcher polls this
    /// case); nil on unparseable content, because the LAUNCH LOOP is the
    /// caller that decides what unparseable means (keep waiting — the file
    /// may still be mid-write). The file PERSISTS after browser death
    /// (measured), so it is only ever read inside the launch loop, never
    /// trusted after.
    public static func read(in profileDirectory: URL) -> DevtoolsEndpoint? {
        let file = profileDirectory.appendingPathComponent("DevToolsActivePort")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return nil
        }
        return try? DevtoolsEndpoint.parse(text)
    }
}
