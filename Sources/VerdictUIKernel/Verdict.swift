// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// The product's core output: a machine-readable PASS/FAIL with cited evidence.
/// Every verification path (lint, diff, cross-validation, pixel compare)
/// terminates in one of these.
public struct Verdict: Equatable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pass = "PASS"
        case fail = "FAIL"
    }

    /// Name of the scenario that produced this verdict.
    public var scenario: String
    /// Derived from ``findings``: any `error` makes the verdict a FAIL.
    public var status: Status
    public var findings: [Finding]

    public init(scenario: String = "unnamed", findings: [Finding]) {
        self.scenario = scenario
        self.findings = findings
        self.status = findings.contains(where: { $0.severity == .error }) ? .fail : .pass
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
