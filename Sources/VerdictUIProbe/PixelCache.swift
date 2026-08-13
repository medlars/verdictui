// VerdictUIProbe — Wave 9 Task 5: the render cache.
//
// Rendering a screen to pixels is the most expensive thing this product does,
// and an agent verifying a change re-renders every scenario it did not touch.
// So captures are cached — and a pixel cache is the most dangerous cache a
// verification tool can have, because a stale hit does not merely serve old
// data: it reports PASS for a screen that has since broken, using evidence from
// before the break. That is the one failure mode this whole product exists to
// prevent, arriving through its own optimisation.
//
// The design therefore starts from the miss, not the hit. Every input that can
// change a rendered pixel is folded into the key, and anything the key cannot
// observe is not allowed to be an input. `CacheKey` names each component and
// says why it is there, so adding a new render input without extending the key
// is a visible omission rather than an invisible one.
//
// ### What is in the key, and why each is load-bearing
//
// | Component | A change here changes pixels because |
// | --- | --- |
// | `scenario` | different screen entirely |
// | `treeHash` | the layout settled differently — state, data, or a real regression |
// | `viewport` | different size, different line breaks |
// | `variant` | locale, colour scheme, dynamic type and layout direction — every environment axis, taken from `Variant` so a new axis arrives here automatically rather than being hand-copied and forgotten |
// | `backend` | measured to produce different bytes for the same view (Wave 9 Task 1) |
// | `buildID` | the code that draws the pixels changed |
//
// `treeHash` deserves its own note, because it is what makes the rest safe. The
// semantic tree is computed from the SAME render the pixels come from, so any
// state change that reaches the screen reaches the tree first. That makes the
// tree a proxy for "everything the scenario's body depended on" without the
// cache having to enumerate application state it cannot see.
//
// `buildID` is the component most easily forgotten and the most consequential:
// without it, editing the view code and re-running serves the pixels of the
// PREVIOUS build, so a session verifying its own change is shown the state
// before that change. It is derived from the mtime of the running binary rather
// than a compile-time constant, because a constant baked at build time is
// identical across two builds of different source unless something explicitly
// varies it.
import AppKit
import CryptoKit
import Foundation
import VerdictUIKernel

// MARK: - Key

/// Everything that can change a rendered pixel, folded into one identity.
///
/// A cache entry is valid only for an identical key. The type is a struct of
/// named components rather than a pre-hashed string so that a reader can see
/// what the cache considers relevant — and, more importantly, see what it does
/// not.
public struct PixelCacheKey: Equatable, Sendable {
    /// Scenario name.
    public let scenario: String

    /// Canonical hash of the semantic tree this capture was taken alongside.
    ///
    /// The component that makes the others safe: the tree is computed from the
    /// same render pass as the pixels, so any application state that reached the
    /// screen reached the tree, and the cache need not enumerate state it cannot
    /// observe.
    public let treeHash: String

    /// Rendered size in points.
    public let viewport: Size

    /// Every environment axis the host rendered with, as one component.
    ///
    /// `Variant.name` rather than four hand-copied strings, and that is the
    /// point: `Variant` is the type that ENUMERATES the render environment, so
    /// an axis added there arrives here automatically. Four copied fields would
    /// be four places to forget, and forgetting one means two different renders
    /// share a key and serve each other's pixels.
    public let variant: String

    /// Which capture backend produced the bytes.
    public let backend: PixelBackend

    /// Identity of the build that drew the pixels.
    ///
    /// Without this the cache serves the previous build's pixels after a code
    /// change — showing a session the screen as it was BEFORE the edit it is
    /// verifying, which is the worst answer available.
    public let buildID: String

    public init(
        scenario: String,
        treeHash: String,
        viewport: Size,
        variant: String,
        backend: PixelBackend,
        buildID: String = PixelCache.currentBuildID
    ) {
        self.scenario = scenario
        self.treeHash = treeHash
        self.viewport = viewport
        self.variant = variant
        self.backend = backend
        self.buildID = buildID
    }

    /// Content hash of a semantic tree, for use as ``treeHash``.
    ///
    /// Encoded with sorted keys so two structurally-identical trees hash the
    /// same regardless of dictionary iteration order — without that the key
    /// would vary between runs of unchanged code and the cache would never hit,
    /// which is the failure that looks like the cache simply not helping.
    ///
    /// A tree that cannot be encoded yields a per-call unique value, so it
    /// MISSES rather than colliding with every other unencodable tree. A cache
    /// that cannot compute an identity must not invent a shared one.
    public static func hash(tree: SemanticNode) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(tree) else {
            return "unhashable-\(UUID().uuidString)"
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stable filename-safe digest of every component.
    ///
    /// SHA-256 over a delimited rendering of the fields. The delimiter matters:
    /// concatenating them raw would let two different keys collide by moving a
    /// character across a boundary (`"ab" + "c"` and `"a" + "bc"`), and a cache
    /// collision here means serving one scenario's pixels for another.
    public var digest: String {
        let joined = [
            scenario, treeHash,
            "\(viewport.width)x\(viewport.height)",
            variant, backend.rawValue, buildID,
        ].joined(separator: "\u{1F}")
        let hash = SHA256.hash(data: Data(joined.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

/// Why the cache could not serve or store an entry.
public enum PixelCacheError: Error, CustomStringConvertible, Equatable {
    /// The cache directory could not be created or written.
    case unwritable(path: String, reason: String)

    /// A stored entry existed but could not be read back as a capture.
    ///
    /// Treated as a MISS by the reading path rather than as an error, and
    /// reported only by the direct-read API — a corrupt entry must never fail a
    /// verification run, because the correct response is to render again.
    case corruptEntry(digest: String)

    public var description: String {
        switch self {
        case let .unwritable(path, reason):
            return """
                pixel cache is unwritable at '\(path)': \(reason). Verification still \
                works — every lookup will simply miss and re-render.
                """
        case let .corruptEntry(digest):
            return """
                pixel cache entry '\(digest)' could not be read back as a capture. It has \
                been discarded; the scenario will re-render.
                """
        }
    }
}

// MARK: - The cache

/// Content-addressed store of rendered captures.
///
/// Entries are keyed by ``PixelCacheKey/digest``, so an entry is unreachable the
/// moment any input changes — invalidation is by construction rather than by an
/// eviction policy that has to be right. There is no "clear the cache after
/// editing" step for anyone to forget.
public struct PixelCache: Sendable {
    /// Directory entries are stored in.
    public let directory: URL

    /// Default location: `~/.verdictui/cache/pixels`.
    public static func standard(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> PixelCache {
        PixelCache(
            directory: home
                .appendingPathComponent(".verdictui", isDirectory: true)
                .appendingPathComponent("cache", isDirectory: true)
                .appendingPathComponent("pixels", isDirectory: true)
        )
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// Identity of the running build, derived from the executable's modification
    /// time.
    ///
    /// An mtime rather than a compile-time constant because a constant baked at
    /// build time is IDENTICAL across two builds of different source unless
    /// something explicitly varies it — which is exactly the case that must
    /// invalidate. Falls back to a per-process UUID when the executable cannot
    /// be stat'd, which disables the cache for that process rather than risking
    /// a stale hit: a cache that cannot prove freshness must not claim it.
    public static let currentBuildID: String = {
        let path = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
            let modified = attributes[.modificationDate] as? Date
        else {
            return "unstamped-\(UUID().uuidString)"
        }
        return String(format: "%.0f", modified.timeIntervalSince1970)
    }()

    /// File an entry is stored at.
    func url(for key: PixelCacheKey) -> URL {
        directory.appendingPathComponent("\(key.digest).png")
    }

    /// Sidecar recording the dimensions and scenario, so a hit reconstructs a
    /// full ``PixelCapture`` rather than a bare PNG.
    func metadataURL(for key: PixelCacheKey) -> URL {
        directory.appendingPathComponent("\(key.digest).json")
    }

    /// Fetch a cached capture, or `nil` on a miss.
    ///
    /// Never throws. Every failure — a missing file, unreadable bytes, corrupt
    /// metadata — is a MISS, because the correct response to all of them is to
    /// render again. A cache that can fail a verification run has made the
    /// product less reliable in exchange for making it faster.
    public func fetch(_ key: PixelCacheKey) -> PixelCapture? {
        guard
            let png = try? Data(contentsOf: url(for: key)),
            let metadata = try? Data(contentsOf: metadataURL(for: key)),
            let stored = try? JSONDecoder().decode(StoredMetadata.self, from: metadata)
        else { return nil }

        let capture = PixelCapture(
            png: png,
            pixelsWide: stored.pixelsWide,
            pixelsHigh: stored.pixelsHigh,
            backend: stored.backend,
            scenarioName: stored.scenarioName
        )
        // The stored hash is checked against the bytes actually read, so a
        // truncated or partially-written file misses instead of being served as
        // a valid capture — the shape a crash mid-write leaves behind.
        guard capture.contentHash == stored.contentHash else { return nil }
        return capture
    }

    /// Store a capture under `key`.
    ///
    /// - Throws: ``PixelCacheError/unwritable(path:reason:)``. Storing is allowed
    ///   to fail loudly because a caller can choose to ignore it — unlike a
    ///   fetch, a failed store cannot produce a wrong answer.
    public func store(_ capture: PixelCapture, for key: PixelCacheKey) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw PixelCacheError.unwritable(
                path: directory.path, reason: error.localizedDescription)
        }

        let metadata = StoredMetadata(
            scenarioName: capture.scenarioName,
            pixelsWide: capture.pixelsWide,
            pixelsHigh: capture.pixelsHigh,
            backend: capture.backend,
            contentHash: capture.contentHash
        )
        do {
            // The PNG lands first and the metadata second, so a crash between
            // the two leaves an orphan PNG with no metadata — which fetches as a
            // MISS. The other order would leave metadata pointing at bytes that
            // do not exist, and a reader that trusted it would serve a phantom.
            try capture.png.write(to: url(for: key))
            try JSONEncoder().encode(metadata).write(to: metadataURL(for: key))
        } catch {
            throw PixelCacheError.unwritable(
                path: directory.path, reason: error.localizedDescription)
        }
    }

    /// Remove every entry. For tests and for a human who wants a clean slate;
    /// correctness never depends on it, because invalidation is by key.
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw PixelCacheError.unwritable(
                path: directory.path, reason: error.localizedDescription)
        }
    }

    /// What a `.json` sidecar carries.
    struct StoredMetadata: Codable, Equatable {
        let scenarioName: String
        let pixelsWide: Int
        let pixelsHigh: Int
        let backend: PixelBackend
        let contentHash: String
    }
}

// MARK: - Cached capture

extension OracleHost {
    /// Capture through the cache, rendering only on a miss.
    ///
    /// - Parameters:
    ///   - tree: the semantic tree from THIS host's settle, whose hash is the
    ///     key component that makes the rest safe. Required rather than
    ///     optional: a cache key computed without it could not see a state
    ///     change, and a caller who has settled the host already holds one.
    /// - Returns: the capture and whether it came from the cache, so a caller
    ///   can report the hit rate rather than guess at it.
    public func capturePixelsCached(
        tree: SemanticNode,
        cache: PixelCache,
        backend: PixelBackend = .cacheDisplay
    ) throws -> (capture: PixelCapture, wasHit: Bool) {
        let key = cacheKey(tree: tree, backend: backend)
        if let hit = cache.fetch(key) {
            return (hit, true)
        }
        let capture = try capturePixels(backend: backend)
        // A store failure is swallowed on purpose: it makes the next run slower,
        // never wrong, and failing a verification because a cache directory is
        // read-only would be the optimisation breaking the product.
        try? cache.store(capture, for: key)
        return (capture, false)
    }

    /// The cache identity of this host's current render.
    ///
    /// Reads the variant the host RENDERED WITH rather than the machine's
    /// settings, so the key describes what was actually drawn. Reading the
    /// machine would make two hosts pinned to different locales collide.
    public func cacheKey(tree: SemanticNode, backend: PixelBackend) -> PixelCacheKey {
        PixelCacheKey(
            scenario: scenarioName,
            treeHash: PixelCacheKey.hash(tree: tree),
            viewport: hostSize,
            variant: variant.name,
            backend: backend
        )
    }
}
