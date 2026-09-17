import Foundation

/// Owns the on-disk shape of web profiles: one named directory per identity,
/// plus the locks directory that arbitrates sessions.
///
/// Layout (Wave 11 spec, concurrency design):
///
///     <root>/
///       <name>/            — the --user-data-dir for profile `name`
///       locks/<name>.lock  — pidfile, content = holding pid as text
///
/// Each SESSION on a profile is arbitrated by that one lock; two sessions on
/// one profile can never attach to one browser by construction (G4). A
/// session wanting a fresh identity uses a fresh profile name.
public struct ProfileRegistry {
    /// The root every profile and lock lives under.
    public let root: URL

    /// The default root: the app-support path the spec names.
    public static func defaultRoot(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(
                "Library/Application Support/VerdictUI/web-profiles")
    }

    /// - Parameter root: the registry root directory.
    public init(root: URL = ProfileRegistry.defaultRoot()) {
        self.root = root
    }

    /// The directory a profile's browser data lives in.
    public func profileDirectory(for name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    /// The pidfile path for a profile's lock.
    public func lockPath(for name: String) -> URL {
        root.appendingPathComponent("locks", isDirectory: true)
            .appendingPathComponent("\(name).lock")
    }

    /// Create the profile directory, validating the name first.
    ///
    /// The browser treats this directory as its `--user-data-dir`, so the
    /// name must be a single safe path component — a traversal name would
    /// place browser data (and later, cookies) outside the registry root.
    @discardableResult
    public func makeProfileDirectory(named name: String) throws -> URL {
        try ProfileName.validate(name)
        let dir = profileDirectory(for: name)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Validation for profile names: the boundary between a caller's string and
/// the filesystem.
public enum ProfileName {
    /// Accept exactly a single safe path component.
    public static func validate(_ name: String) throws {
        guard !name.isEmpty,
            !name.contains("/"),
            name != ".",
            name != "..",
            !name.contains("\0")
        else {
            throw WebBrowserError.invalidProfileName(name: name)
        }
    }
}
