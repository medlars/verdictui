// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// A declarative claim about one element, compiled to ``Finding``s.
///
/// The rule library answers "is anything obviously wrong?"; expectations answer
/// "is this screen the one I meant?". A rule cannot know that the save button
/// should say "Save" and sit right of Cancel — only the author knows that, and
/// before this type the only way to say it was a hand-written frame assertion in
/// a test, which is exactly the code this product exists to delete.
///
/// ```swift
/// let findings = Expectation("save-button")
///     .visible
///     .enabled
///     .text("Save")
///     .rightOf("cancel-button")
///     .width(.atLeast(80))
///     .evaluate(in: tree, context: context)
/// ```
///
/// ## Why a missing node is an ERROR and not a silent pass
///
/// The failure mode this type exists to avoid is an expectation that quietly
/// stops testing anything. If `save-button` is renamed, deleted, or never
/// probed, every predicate on it has nothing to check — and a "no node, no
/// findings" reading turns the whole expectation into a green no-op. That is
/// the vacuity shape ``RuleEngine/vacuousVerdictRule`` guards at tree level,
/// arriving one layer down, so a missing subject is itself the finding.
public struct Expectation: Sendable {
    /// Rule id every expectation finding carries.
    ///
    /// One id rather than one per predicate: findings are grouped and suppressed
    /// by rule, and an author who wants to silence "my expectations" should not
    /// have to enumerate the predicate vocabulary. The predicate that failed is
    /// named in the message instead.
    public static let id = "expectation"

    /// Probe id of the element under test.
    public let nodeID: String

    /// Predicates to check, in declaration order — findings are emitted in the
    /// order the author wrote them, so the evidence reads like the source.
    private var predicates: [Predicate]

    public init(_ nodeID: String) {
        self.nodeID = nodeID
        self.predicates = []
    }

    private func adding(_ predicate: Predicate) -> Expectation {
        var copy = self
        copy.predicates.append(predicate)
        return copy
    }

    // MARK: - State predicates

    /// The element renders.
    public var visible: Expectation { adding(.visible) }

    /// The element is not disabled.
    ///
    /// Reads `attributes["enabled"]`, and a node that does not carry the
    /// attribute is treated as enabled — the probe only records it for controls
    /// that can be disabled, and demanding its presence would fail every
    /// element that has no such state.
    public var enabled: Expectation { adding(.enabled) }

    /// The element's text equals `value` exactly.
    public func text(_ value: String) -> Expectation { adding(.text(value)) }

    /// The element's text contains `value`.
    public func textContains(_ value: String) -> Expectation {
        adding(.textContains(value))
    }

    /// The element's role is `role`.
    public func role(_ role: Role) -> Expectation { adding(.role(role)) }

    // MARK: - Dimension predicates

    /// The element's width satisfies `constraint`.
    public func width(_ constraint: DimensionConstraint) -> Expectation {
        adding(.width(constraint))
    }

    /// The element's height satisfies `constraint`.
    public func height(_ constraint: DimensionConstraint) -> Expectation {
        adding(.height(constraint))
    }

    // MARK: - Relational predicates

    /// This element sits entirely to the right of `other`.
    public func rightOf(_ other: String) -> Expectation { adding(.rightOf(other)) }

    /// This element sits entirely to the left of `other`.
    public func leftOf(_ other: String) -> Expectation { adding(.leftOf(other)) }

    /// This element sits entirely above `other`.
    public func above(_ other: String) -> Expectation { adding(.above(other)) }

    /// This element sits entirely below `other`.
    public func below(_ other: String) -> Expectation { adding(.below(other)) }

    /// This element's frame lies inside `other`'s.
    public func contained(in other: String) -> Expectation { adding(.contained(other)) }

    /// This element lies entirely within the rendered viewport.
    ///
    /// The predicate that ``contained(in:)`` cannot express: the viewport is not
    /// a node, so it has no probe id to name. It arrives on ``LintContext``
    /// instead, which is why this is the one predicate whose evaluation needs
    /// the context.
    ///
    /// Added in Wave 5 when the DSL was first dogfooded on the demo catalog and
    /// could not state ``OffscreenButtonScenario``'s intent. `.visible` is not a
    /// substitute and the difference is load-bearing: ``SemanticNode/isVisible``
    /// is always `true` from the layout pass (opacity and clipping are not
    /// observable there), so an element parked at `x: 420` in a 320 pt viewport
    /// is `visible`, `enabled`, correctly sized and below its title — every
    /// sentence an author could previously write about it was satisfied while
    /// the user could not see or reach it.
    public var onscreen: Expectation { adding(.onscreen) }

    /// This element shares `edge` with `other`, within ``alignmentTolerance``.
    public func aligned(_ edge: MisalignmentRule.Edge, with other: String) -> Expectation {
        adding(.aligned(edge, other))
    }

    /// Slack allowed by ``aligned(_:with:)`` and the relational predicates.
    ///
    /// The float-noise band the geometry rules already share. Alignment asserted
    /// by an author is a stronger claim than ``MisalignmentRule``'s inference,
    /// so it is held to the tighter of the two bounds: a 3 pt miss is a
    /// near-miss the rule reports as a smell, and an expectation saying "these
    /// are aligned" is simply wrong at 3 pt.
    public static let alignmentTolerance = 0.5

    // MARK: - Evaluation

    /// Check every predicate against `tree`, returning one finding per failure.
    ///
    /// All predicates are evaluated rather than stopping at the first failure:
    /// an author fixing a screen wants the whole list, not a drip-feed that
    /// costs one verify cycle per problem.
    public func evaluate(in tree: SemanticNode, context: LintContext) -> [Finding] {
        guard let node = tree.node(withID: nodeID) else {
            // Deliberately NOT routed through `context.makeFinding`: that
            // consults per-node suppression, and there is no node here to carry
            // a suppression attribute. A missing subject must not be silenceable
            // by the absent element's own markup.
            return [
                Finding(
                    rule: Self.id,
                    severity: .error,
                    nodeID: nodeID,
                    message: "expected '\(nodeID)' but no such element is in the tree",
                    suggestion: "check the probe id, or attach .verdictProbe(\"\(nodeID)\") "
                        + "to the element this expectation describes"
                )
            ]
        }

        return predicates.compactMap { predicate in
            guard let failure = predicate.failure(for: node, in: tree, context: context) else {
                return nil
            }
            return context.makeFinding(
                rule: Self.id,
                node: node,
                message: "'\(nodeID)' \(failure.message)",
                suggestion: failure.suggestion,
                defaultSeverity: .error
            )
        }
    }
}

/// A bound on a measured dimension.
public enum DimensionConstraint: Sendable, Equatable {
    /// Exactly `value`, within half a point of layout noise.
    case exactly(Double)
    /// At least `value`.
    case atLeast(Double)
    /// At most `value`.
    case atMost(Double)
    /// Between `lower` and `upper`, inclusive.
    case between(Double, Double)

    /// Slack for ``exactly(_:)``, matching the geometry rules' noise band.
    static let tolerance = 0.5

    func isSatisfied(by measured: Double) -> Bool {
        // A non-finite measurement satisfies nothing: `.nan` compares false
        // against every bound, so an unplaceable frame would otherwise slip
        // through `atMost` by accident of IEEE semantics rather than by being
        // correct.
        guard measured.isFinite else { return false }
        switch self {
        case .exactly(let value): return abs(measured - value) <= Self.tolerance
        case .atLeast(let value): return measured >= value
        case .atMost(let value): return measured <= value
        case .between(let lower, let upper): return measured >= lower && measured <= upper
        }
    }

    /// How a finding describes this bound.
    var description: String {
        switch self {
        case .exactly(let value): "exactly \(value.pointsDescription) pt"
        case .atLeast(let value): "at least \(value.pointsDescription) pt"
        case .atMost(let value): "at most \(value.pointsDescription) pt"
        case .between(let lower, let upper):
            "between \(lower.pointsDescription) and \(upper.pointsDescription) pt"
        }
    }
}

extension Expectation {
    /// Why one predicate failed: the clause for the message, and a repair hint.
    struct Failure {
        let message: String
        let suggestion: String?
    }

    /// The predicate vocabulary.
    ///
    /// An enum rather than a closure-carrying struct, for the reason
    /// ``MisalignmentRule/Edge`` is one: `Expectation` is `Sendable` so the
    /// Wave 6 daemon can hold compiled expectations across concurrent verifies,
    /// and a stored closure is not.
    enum Predicate: Sendable {
        case visible
        case enabled
        case text(String)
        case textContains(String)
        case role(Role)
        case width(DimensionConstraint)
        case height(DimensionConstraint)
        case rightOf(String)
        case leftOf(String)
        case above(String)
        case below(String)
        case contained(String)
        case onscreen
        case aligned(MisalignmentRule.Edge, String)

        /// The failure this predicate reports for `node`, or `nil` when satisfied.
        ///
        /// `context` is taken because ``onscreen`` is judged against the
        /// viewport, which is not a node and therefore cannot be reached
        /// through `tree`.
        func failure(
            for node: SemanticNode,
            in tree: SemanticNode,
            context: LintContext
        ) -> Failure? {
            switch self {
            case .visible:
                return node.isVisible
                    ? nil
                    : Failure(
                        message: "is not visible",
                        suggestion: "remove the .hidden() or .opacity(0) hiding this element"
                    )

            case .enabled:
                // Absent means enabled: the probe records this only for controls
                // that can be disabled, so demanding the attribute would fail
                // every element with no such state.
                let isEnabled = node.attributes["enabled"]?.boolValue ?? true
                return isEnabled
                    ? nil
                    : Failure(
                        message: "is disabled",
                        suggestion: "check the .disabled() condition guarding this control"
                    )

            case .text(let expected):
                let actual = node.text
                return actual == expected
                    ? nil
                    : Failure(
                        message: "reads \(Self.quoted(actual)) but was expected to read "
                            + "\"\(expected)\"",
                        suggestion: "update the element's text, or the expectation if the "
                            + "new wording is intended"
                    )

            case .textContains(let needle):
                return node.text?.contains(needle) == true
                    ? nil
                    : Failure(
                        message: "reads \(Self.quoted(node.text)) which does not contain "
                            + "\"\(needle)\"",
                        suggestion: nil
                    )

            case .role(let expected):
                return node.role == expected
                    ? nil
                    : Failure(
                        message: "is a \(node.role.identifier) but was expected to be a "
                            + "\(expected.identifier)",
                        suggestion: "check the role passed to .verdictProbe(_:role:)"
                    )

            case .width(let constraint):
                return constraint.isSatisfied(by: node.frame.width)
                    ? nil
                    : Failure(
                        message: "is \(node.frame.width.pointsDescription) pt wide, expected "
                            + constraint.description,
                        suggestion: "adjust the element's frame or its content"
                    )

            case .height(let constraint):
                return constraint.isSatisfied(by: node.frame.height)
                    ? nil
                    : Failure(
                        message: "is \(node.frame.height.pointsDescription) pt tall, expected "
                            + constraint.description,
                        suggestion: "adjust the element's frame or its content"
                    )

            case .rightOf(let other):
                return Self.relation(
                    node, other, in: tree, clause: "to the right of",
                    holds: { $0.frame.x >= $1.frame.maxX - Expectation.alignmentTolerance }
                )

            case .leftOf(let other):
                return Self.relation(
                    node, other, in: tree, clause: "to the left of",
                    holds: { $0.frame.maxX <= $1.frame.x + Expectation.alignmentTolerance }
                )

            case .above(let other):
                return Self.relation(
                    node, other, in: tree, clause: "above",
                    holds: { $0.frame.maxY <= $1.frame.y + Expectation.alignmentTolerance }
                )

            case .below(let other):
                return Self.relation(
                    node, other, in: tree, clause: "below",
                    holds: { $0.frame.y >= $1.frame.maxY - Expectation.alignmentTolerance }
                )

            case .contained(let other):
                return Self.relation(
                    node, other, in: tree, clause: "inside",
                    holds: { $1.frame.contains($0.frame) }
                )

            case .onscreen:
                // Judged against the viewport RECTANGLE, not merely its size:
                // a frame at negative x is as unreachable as one past the
                // trailing edge, and a width-only comparison would call the
                // first one satisfied.
                return context.viewport.contains(node.frame)
                    ? nil
                    : Failure(
                        message: "renders at \(node.frame) which is not inside the "
                            + "\(context.viewport) viewport",
                        suggestion: "the element is laid out beyond the visible area — check "
                            + "for a fixed offset, a negative padding, or a parent wider than "
                            + "the viewport"
                    )

            case .aligned(let edge, let other):
                return Self.relation(
                    node, other, in: tree, clause: "\(edge.name)-aligned with",
                    holds: {
                        abs(edge.value(of: $0.frame) - edge.value(of: $1.frame))
                            <= Expectation.alignmentTolerance
                    }
                )
            }
        }

        /// Evaluate a two-element predicate, reporting a missing counterpart as
        /// its own failure.
        ///
        /// A relation whose other side is absent cannot be true OR false, and
        /// answering either would be a claim the tree does not support —
        /// "rightOf a node that does not exist" reported as satisfied is the
        /// vacuity shape again, one predicate down.
        private static func relation(
            _ node: SemanticNode,
            _ otherID: String,
            in tree: SemanticNode,
            clause: String,
            holds: (SemanticNode, SemanticNode) -> Bool
        ) -> Failure? {
            guard let other = tree.node(withID: otherID) else {
                return Failure(
                    message: "was expected \(clause) '\(otherID)', which is not in the tree",
                    suggestion: "check the probe id '\(otherID)'"
                )
            }
            return holds(node, other)
                ? nil
                : Failure(
                    message: "is not \(clause) '\(otherID)'",
                    suggestion: "move the elements, or correct the expectation"
                )
        }

        /// Render an optional string for a message: `"Save"` or `no text`.
        private static func quoted(_ value: String?) -> String {
            value.map { "\"\($0)\"" } ?? "no text"
        }
    }
}

/// A named group of expectations, evaluated together.
///
/// The unit a scenario declares and the CLI names, so an author writes one
/// `ExpectationSet` per screen state rather than threading a bare array.
public struct ExpectationSet: Sendable {
    /// What this set describes, e.g. `"settings — logged out"`.
    public let name: String
    /// The expectations, evaluated in declaration order.
    public let expectations: [Expectation]

    public init(_ name: String, _ expectations: [Expectation]) {
        self.name = name
        self.expectations = expectations
    }

    /// Findings from every expectation in the set.
    public func evaluate(in tree: SemanticNode, context: LintContext) -> [Finding] {
        expectations.flatMap { $0.evaluate(in: tree, context: context) }
    }
}
