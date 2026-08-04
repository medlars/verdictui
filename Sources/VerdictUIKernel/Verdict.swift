// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// The product's core output: a machine-readable PASS/FAIL with cited evidence.
/// Every verification path (lint, diff, cross-validation, pixel compare)
/// terminates in one of these.
///
/// This struct *is* the wire format pinned by `contracts/verdict-schema.json`;
/// its encoded shape is a contract, not an implementation detail. Absent fields
/// are omitted rather than encoded as `null`, keeping the payload small for the
/// token-metered MCP surface.
public struct Verdict: Equatable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pass = "PASS"
        case fail = "FAIL"

        /// The only place status is computed. Both the initializer and the
        /// decoder route through here so the rule cannot drift between the
        /// verdicts this kernel produces and the ones it accepts.
        public static func derived(from findings: [Finding]) -> Status {
            findings.contains { $0.severity == .error } ? .fail : .pass
        }
    }

    /// Where the wall-clock cost went. Populated as the pipeline grows: Wave 1
    /// measures `evaluateMs`, Wave 3's settle engine fills `settleMs`.
    public struct Timing: Equatable, Codable, Sendable {
        /// Milliseconds spent waiting for the UI to go quiescent.
        public var settleMs: Double?
        /// Milliseconds spent running lint rules over the tree.
        public var evaluateMs: Double?

        public init(settleMs: Double? = nil, evaluateMs: Double? = nil) {
            self.settleMs = settleMs
            self.evaluateMs = evaluateMs
        }
    }

    /// Wire-format version, always ``SchemaVersion/current`` on encode.
    public var schemaVersion: String
    /// Name of the scenario that produced this verdict.
    public var scenario: String
    /// When the verdict was produced, at whole-second precision (see ``init``).
    public var timestamp: Date
    /// Derived from ``findings``: any `error` makes the verdict a FAIL.
    public var status: Status
    /// The evidence. A verdict without findings is a PASS; a verdict with an
    /// error finding is a FAIL that names the node and rule responsible.
    public var findings: [Finding]
    /// The tree the verdict was computed from, when the caller asked for it.
    public var tree: SemanticNode?
    /// What changed since the previous observation, for act-and-observe steps.
    public var delta: TreeDelta?
    public var timing: Timing

    /// - Parameter timestamp: truncated to whole seconds, because that is the
    ///   precision the ISO-8601 wire form carries — storing more would make
    ///   encode/decode lossy and break verdict comparison.
    public init(
        scenario: String = "unnamed",
        findings: [Finding],
        timestamp: Date = Date(),
        tree: SemanticNode? = nil,
        delta: TreeDelta? = nil,
        timing: Timing = Timing()
    ) {
        self.schemaVersion = SchemaVersion.current
        self.scenario = scenario
        self.timestamp = Date(
            timeIntervalSince1970: timestamp.timeIntervalSince1970.rounded(.down)
        )
        self.findings = findings
        self.status = Status.derived(from: findings)
        self.tree = tree
        self.delta = delta
        self.timing = timing
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, scenario, timestamp, status, findings, tree, delta, timing
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        scenario = try container.decode(String.self, forKey: .scenario)
        let stamp = try container.decode(String.self, forKey: .timestamp)
        do {
            timestamp = try Date.ISO8601FormatStyle(timeZone: .gmt).parse(stamp)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp,
                in: container,
                debugDescription: "expected an ISO-8601 UTC timestamp, got '\(stamp)'"
            )
        }
        let declared = try container.decode(Status.self, forKey: .status)
        findings = try container.decode([Finding].self, forKey: .findings)
        // Status is derived, never set — so a payload whose status contradicts its
        // own findings is corrupt, not merely stale. Recomputing it silently would
        // paper over a broken producer and let a verdict carrying an error finding
        // be reported as PASS by whatever consumed it.
        let derived = Status.derived(from: findings)
        guard declared == derived else {
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: """
                    status '\(declared.rawValue)' contradicts the findings, which \
                    derive '\(derived.rawValue)'
                    """
            )
        }
        status = derived
        tree = try container.decodeIfPresent(SemanticNode.self, forKey: .tree)
        delta = try container.decodeIfPresent(TreeDelta.self, forKey: .delta)
        timing = try container.decodeIfPresent(Timing.self, forKey: .timing) ?? Timing()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(scenario, forKey: .scenario)
        try container.encode(
            timestamp.formatted(Date.ISO8601FormatStyle(timeZone: .gmt)),
            forKey: .timestamp
        )
        try container.encode(status, forKey: .status)
        try container.encode(findings, forKey: .findings)
        try container.encodeIfPresent(tree, forKey: .tree)
        try container.encodeIfPresent(delta, forKey: .delta)
        try container.encode(timing, forKey: .timing)
    }
}

/// One piece of evidence-backed feedback. `nodeID` ties the finding back to a
/// probed element so agents can self-correct without guessing.
public struct Finding: Equatable, Codable, Sendable {
    public enum Severity: String, Codable, Sendable {
        case error
        case warning
    }

    public var rule: String
    public var severity: Severity
    public var nodeID: String
    public var message: String
    /// Machine-actionable repair hint, e.g. "increase frame width to >= intrinsic
    /// width 212 pt". Present whenever the rule can name a concrete fix — this is
    /// what turns a verdict into an edit an agent can make without guessing.
    public var suggestion: String?

    public init(
        rule: String,
        severity: Severity,
        nodeID: String,
        message: String,
        suggestion: String? = nil
    ) {
        self.rule = rule
        self.severity = severity
        self.nodeID = nodeID
        self.message = message
        self.suggestion = suggestion
    }
}
