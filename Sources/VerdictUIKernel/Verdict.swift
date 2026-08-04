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

    public var status: Status
    public var findings: [Finding]

    public init(findings: [Finding]) {
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

    public init(rule: String, severity: Severity, nodeID: String, message: String) {
        self.rule = rule
        self.severity = severity
        self.nodeID = nodeID
        self.message = message
    }
}

/// Wave 1 seed rule: two sibling nodes must not overlap unless one is an
/// ancestor of the other. Proves the kernel pipeline (tree in → findings out)
/// end-to-end; the full rule library lands in Wave 5.
public enum LayoutLint {
    public static func siblingOverlaps(in root: SemanticNode) -> [Finding] {
        var findings: [Finding] = []
        walk(root) { node in
            for i in node.children.indices {
                for j in node.children.indices where j > i {
                    let a = node.children[i]
                    let b = node.children[j]
                    if !a.frame.isEmpty, !b.frame.isEmpty, a.frame.intersects(b.frame) {
                        findings.append(
                            Finding(
                                rule: "sibling-overlap",
                                severity: .error,
                                nodeID: b.id,
                                message: "'\(b.id)' overlaps sibling '\(a.id)'"
                            )
                        )
                    }
                }
            }
        }
        return findings
    }

    private static func walk(_ node: SemanticNode, _ visit: (SemanticNode) -> Void) {
        visit(node)
        for child in node.children {
            walk(child, visit)
        }
    }
}
