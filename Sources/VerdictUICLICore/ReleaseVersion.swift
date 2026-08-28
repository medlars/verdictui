import VerdictUIKernel

/// The version of THIS BUILD, as users install it.
///
/// Distinct from `SchemaVersion.current` on purpose, and the distinction is the
/// point: the wire schema is a 1.0 compatibility promise (ADR 2026-022) that
/// must stay stable across releases, so it cannot double as a release
/// identifier — the two have opposite change rates by design.
///
/// Measured 2026-08-28 against the v1.0.1 tarball: `verdictui --version`
/// printed `1.1`, which matches no release and cannot distinguish two builds
/// that share a schema. A bug report saying "1.1" did not say which binary.
///
/// Bumped when a release is cut, beside the git tag.
public enum ReleaseVersion {
    public static let current = "1.0.1"

    /// What `--version` prints: the release first, the wire schema after it.
    ///
    /// One line carrying both facts, so neither has to be guessed and neither
    /// is mistaken for the other.
    public static var display: String { "\(current) (schema \(SchemaVersion.current))" }
}
