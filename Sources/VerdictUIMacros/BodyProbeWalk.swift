import SwiftSyntax

/// Rewrites a view's `body` expression, attaching `.verdictProbe(id:role:text:)`
/// to every recognised element expression that does not already carry one.
///
/// This is Wave 4 Task 2 — the part that makes `@Verifiable` buy a *semantic*
/// tree rather than a bare root. It operates on a COPY of the body syntax that
/// becomes `verdictProbedBody`; the view's own `body` is never rewritten, so a
/// `@Verifiable` view renders identically in a real app.
///
/// ## What it can and cannot see
///
/// A macro runs on syntax, before type checking, so recognition is by *spelling*
/// and nothing else: `Text("x")` is recognised, a `let t = Text("x")` referenced
/// later is not, and a custom `MyRow()` is opaque by design (the plan's stated
/// position — nested `@Verifiable` types compose, so the walk probes the layer it
/// can see and stops). Being explicit about that is the point: a walker that
/// guessed at opaque expressions would attach ids to things whose role it cannot
/// know, and a wrong role is worse than an absent one because rules act on it.
struct BodyProbeWalk {
    /// Element spellings the walk recognises, mapped to the role they report.
    ///
    /// Keyed on the *callee identifier* rather than on a matched substring of
    /// the expression text: `Text(...)` and `myText(...)` share a suffix, and a
    /// text match would probe the second as if it were the first (lesson 213 —
    /// attribute a finding to what was parsed, never to text that merely fell
    /// inside the scanned region).
    ///
    /// `role` is the wire spelling of `VerdictUIKernel.Role`, emitted as a
    /// `.member` expression. It is a string here because the plugin cannot
    /// import the kernel — it builds for the host toolchain — so the two are
    /// kept in agreement by `VerifiableRoleVocabularyTests`, which asserts every
    /// spelling below is a real `Role` case.
    static let recognisedElements: [String: String] = [
        "Text": "text",
        "Button": "button",
        "Toggle": "toggle",
        "TextField": "textField",
        "SecureField": "textField",
        "Image": "image",
        "List": "list",
    ]

    /// The type the ids are namespaced under — the view's own name.
    let typeName: String

    /// Per-role counters, so two `Text`s in one body get `.text.0` and `.text.1`.
    private var counts: [String: Int] = [:]

    init(typeName: String) {
        self.typeName = typeName
    }

    /// Rewrites `expression`, returning it with probes attached.
    mutating func rewrite(_ expression: ExprSyntax) -> ExprSyntax {
        // Recurse first, so children of an unrecognised container still get
        // probed. `VStack { Text("a") }` is not itself recognised, and if the
        // walk stopped at unrecognised nodes the body's entire contents would
        // be invisible.
        let recursed = rewriteChildren(of: expression)

        // Already probed by hand: keep this POSITION as the author wrote it.
        // An explicit probe wins over a generated one — that is the documented
        // contract, and re-probing an already probed element would give one
        // view two ids and make `DuplicateProbeIDRule` fire on the macro's own
        // output.
        //
        // Suppression is positional and nothing more. Returning `expression`
        // here — the un-recursed original — would also swallow everything
        // NESTED inside it, so `VStack { Text("a") }.verdictProbe("box")` gave
        // a tree of exactly one node with no content. That is the worst defect
        // shape this product has: `vacuous-verdict` fires only when NO probed
        // node exists, and the container's own probe makes the tree look
        // observed, so every rule reports PASS about content nobody
        // instrumented and no layer anywhere reports the gap.
        if Self.carriesExplicitProbe(recursed) {
            return recursed
        }

        guard let role = Self.recognisedRole(of: recursed) else {
            return recursed
        }

        let index = counts[role, default: 0]
        counts[role] = index + 1
        let id = "\(typeName).\(role).\(index)"

        // A literal string argument is forwarded as `text:` so `TextMetrics`
        // has the string it needs. Only a literal: an interpolated or computed
        // string is not knowable at expansion time, and inventing one would put
        // a false value where the truncation rule reads a real one.
        let textArgument = Self.literalTextArgument(of: recursed).map { ", text: \($0)" } ?? ""

        // Trivia is stripped from the element before the modifier is appended:
        // appending to the expression as-found puts the modifier after whatever
        // whitespace followed it — `Text("x") .verdictProbe(…)`, or across a
        // newline with the closing brace's indentation between them.
        //
        // The element's surrounding indentation is NOT restored, and nothing
        // downstream re-derives it — see the note in `VerifiableMacro.expansion`
        // for why (`SwiftBasicFormat` cannot re-indent lifted code, measured).
        // A multi-line body therefore keeps the indentation it had inside
        // `body`, which the snapshot tests pin as-is.
        let bare = recursed.trimmed
        return
            "\(bare).verdictProbe(\(raw: id.quotedForSource), role: .\(raw: role)\(raw: textArgument))"
    }

    /// Rewrites the closure bodies and argument expressions inside `expression`,
    /// leaving the expression's own shape intact.
    private mutating func rewriteChildren(of expression: ExprSyntax) -> ExprSyntax {
        if let call = expression.as(FunctionCallExprSyntax.self) {
            var updated = call
            updated.calledExpression = descendingChain(call.calledExpression)
            updated.arguments = LabeledExprListSyntax(
                call.arguments.map { argument in
                    var copy = argument
                    copy.expression = rewrite(argument.expression)
                    return copy
                }
            )
            updated.trailingClosure = call.trailingClosure.map { rewriteClosure($0) }
            updated.additionalTrailingClosures = MultipleTrailingClosureElementListSyntax(
                call.additionalTrailingClosures.map { element in
                    var copy = element
                    copy.closure = rewriteClosure(element.closure)
                    return copy
                }
            )
            return ExprSyntax(updated)
        }

        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base {
            var updated = member
            updated.base = descendingChain(base)
            return ExprSyntax(updated)
        }

        return expression
    }

    /// Walks INTO a modifier-chain link to reach the element's children, without
    /// probing anything at this position.
    ///
    /// `VStack { … }.padding(7)` — the most common shape in real SwiftUI — is
    /// an outer `.padding(7)` call whose callee is a member access whose BASE
    /// holds the `VStack` and its closure. Both the callee position and the
    /// member's base sit on that path, so a walk that descends neither leaves
    /// everything inside the container unprobed, and `@Verifiable` yields a tree
    /// with a root and nothing under it. That shipped as a real bug.
    ///
    /// Never `rewrite`: a chain link is not a view expression in its own right.
    /// A probe appended here would wrap the element MID-CHAIN and then the whole
    /// chain would be probed again by the caller's recognition step, which reads
    /// through modifiers — one element, two ids, and `DuplicateProbeIDRule`
    /// reporting the instrumentation itself as the defect.
    ///
    /// Extracted so the guard is expressible as ONE edit. Both call sites are
    /// required — reverting either alone leaves the expansion correct — so while
    /// they were spelled inline no single-line mutation could witness this, and
    /// the catalog row for it scored UNNOTICED while the code was right.
    private mutating func descendingChain(_ expression: ExprSyntax) -> ExprSyntax {
        rewriteChildren(of: expression)
    }

    /// Rewrites the statements a view-builder closure contains.
    private mutating func rewriteClosure(_ closure: ClosureExprSyntax) -> ClosureExprSyntax {
        var updated = closure
        updated.statements = CodeBlockItemListSyntax(
            closure.statements.map { item in
                guard let expression = item.item.as(ExprSyntax.self) else { return item }
                var copy = item
                copy.item = .expr(rewrite(expression))
                return copy
            }
        )
        return updated
    }

    // MARK: - Recognition

    /// The role `expression` reports, or `nil` if the walk does not recognise it.
    ///
    /// Unwraps modifier chains, so `Text("x").padding()` is still a `Text`: the
    /// element is whatever sits at the base of the chain, and refusing to look
    /// through modifiers would leave every styled element unprobed — which is to
    /// say, nearly all of them.
    static func recognisedRole(of expression: ExprSyntax) -> String? {
        guard let callee = calleeIdentifier(of: expression) else { return nil }
        return recognisedElements[callee]
    }

    /// The identifier being *called* at the base of `expression`'s chain.
    static func calleeIdentifier(of expression: ExprSyntax) -> String? {
        if let call = expression.as(FunctionCallExprSyntax.self) {
            if let name = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                return name.baseName.text
            }
            // `Text("x").padding()` — the call's callee is a member access whose
            // own base is the element. Recurse into it rather than reading the
            // member name, which would be `padding`.
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                let base = member.base
            {
                return calleeIdentifier(of: base)
            }
            return nil
        }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base {
            return calleeIdentifier(of: base)
        }
        return nil
    }

    /// Whether `expression` already has a `.verdictProbe` anywhere in its chain.
    ///
    /// Matched on the member NAME at each link, not on the expression's text: a
    /// text search would find `verdictProbe` inside a string literal argument
    /// and silently decline to probe an element that has none.
    static func carriesExplicitProbe(_ expression: ExprSyntax) -> Bool {
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return carriesExplicitProbe(ExprSyntax(call.calledExpression))
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            if member.declName.baseName.text == "verdictProbe" { return true }
            if let base = member.base { return carriesExplicitProbe(base) }
        }
        return false
    }

    /// The first unlabelled string-literal argument of the element call, source
    /// text included, or `nil` when there is none to forward.
    static func literalTextArgument(of expression: ExprSyntax) -> String? {
        guard let call = baseCall(of: expression) else { return nil }
        for argument in call.arguments where argument.label == nil {
            if let literal = argument.expression.as(StringLiteralExprSyntax.self),
                literal.segments.count == 1,
                literal.segments.first?.as(StringSegmentSyntax.self) != nil
            {
                return literal.description
            }
        }
        return nil
    }

    /// The element call at the base of a modifier chain.
    private static func baseCall(of expression: ExprSyntax) -> FunctionCallExprSyntax? {
        if let call = expression.as(FunctionCallExprSyntax.self) {
            if call.calledExpression.is(DeclReferenceExprSyntax.self) { return call }
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                let base = member.base
            {
                return baseCall(of: base)
            }
            return nil
        }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base {
            return baseCall(of: base)
        }
        return nil
    }
}

extension String {
    /// This string as a Swift source string literal.
    ///
    /// Ids are built from a type name and a role, so no escaping is reachable
    /// today; quoting through one helper is what keeps that true if a later
    /// wave derives ids from something an author writes.
    /// Written as a character walk rather than with `replacingOccurrences`
    /// because the plugin does not import Foundation, and adding it to a
    /// compiler plugin for two substitutions is a cost every consumer's build
    /// pays.
    var quotedForSource: String {
        var out = "\""
        for character in self {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            default: out.append(character)
            }
        }
        out += "\""
        return out
    }
}
