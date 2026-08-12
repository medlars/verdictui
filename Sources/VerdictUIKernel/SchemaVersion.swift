// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// Version of the verdict wire format (`contracts/verdict-schema.json`).
///
/// Agents, the CLI, and the MCP server all parse this format, so breaking it
/// silently breaks every consumer. The contract:
/// - **Major** bumps on a breaking change: a removed or renamed field, a narrowed
///   type, a changed meaning. Consumers pinned to an older major must refuse the
///   payload rather than guess.
/// - **Minor** bumps on an additive change: a new optional field. Older consumers
///   keep working by ignoring what they do not know, which is why
///   ``isCompatible(_:)`` only compares majors.
///
/// `contracts/validate-contracts.py` fails if this constant and the JSON schema's
/// declared version drift apart.
public enum SchemaVersion {
    /// The version this kernel emits, as `major.minor`.
    public static let current = "1.1"

    /// Major component of ``current``.
    public static var currentMajor: Int { major(of: current) ?? 0 }

    /// Major component of an arbitrary version string, or `nil` if it is not
    /// `major` / `major.minor` shaped.
    ///
    /// Shape is enforced rather than skimmed: one or two dot-separated
    /// components, each a non-negative integer. Reading `"1.2.3"` as major 1
    /// would accept a payload built to a versioning scheme this kernel does not
    /// know, which is the same "guess rather than refuse" failure
    /// ``isCompatible(_:)`` exists to prevent.
    public static func major(of version: String) -> Int? {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 1 || components.count == 2 else { return nil }
        let numbers = components.compactMap { Int($0) }
        guard numbers.count == components.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        return numbers[0]
    }

    /// Whether a payload declaring `version` can be decoded by this kernel.
    ///
    /// True when the majors match — including a *newer* minor, whose extra fields
    /// this kernel simply ignores. A malformed version string is never compatible.
    public static func isCompatible(_ version: String) -> Bool {
        guard let incoming = major(of: version) else { return false }
        return incoming == currentMajor
    }
}

extension Duration {
    /// This duration in milliseconds, for ``Verdict/Timing``.
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
    }
}
