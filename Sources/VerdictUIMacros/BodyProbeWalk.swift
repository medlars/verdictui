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

    /// Roles whose elements a verdict must be able to NAME, not merely locate.
    ///
    /// Interactive controls only. A `Text` with no literal (`Text(title)`) is
    /// not warned about: its label is its content, which the runtime probe
    /// measures directly, so nothing is lost. A button's label lives inside a
    /// closure the macro cannot evaluate, so if it is not a literal the verdict
    /// has no name for it at all.
    static let rolesRequiringALabel: Set<String> = ["button", "toggle"]

    /// The type the ids are namespaced under — the view's own name.
    let typeName: String

    /// Per-role counters, so two `Text`s in one body get `.text.0` and `.text.1`.
    private var counts: [String: Int] = [:]

    /// Explicit ids already seen, so a second use of one can be reported.
    ///
    /// Only ids the author WROTE go in here. Generated ids cannot collide with
    /// each other by construction (the counter guarantees it) and the walk must
    /// not accuse the author of a collision it minted itself.
    private var explicitIDs: Set<String> = []

    /// Lint findings collected during the walk, for the caller to diagnose.
    ///
    /// Accumulated rather than diagnosed in place because the walk has no
    /// `MacroExpansionContext` — it is a pure syntax-to-syntax transform, which
    /// is what lets `assertMacroExpansion` and the scenario macro drive it
    /// identically. The macro that owns the context turns these into
    /// `Diagnostic`s at the node each finding names.
    private(set) var findings: [ProbeLintFinding] = []

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
            noteExplicitID(of: recursed)
            return recursed
        }

        guard let role = Self.recognisedRole(of: recursed) else {
            return recursed
        }

        let index = counts[role, default: 0]
        counts[role] = index + 1
        let id = "\(typeName).\(role).\(index)"

        // An interactive element the verdict can point at but cannot NAME.
        //
        // The wave plan calls this "no derivable ID", which measurement showed
        // is not the case — the id is derived fine. What is missing is the
        // accessible LABEL: `Button(action:) { Image(…) }` has no literal of
        // its own, so `text:` is absent, `TruncationRule` has nothing to read,
        // no assertion can reference the button by what it says, and a human
        // reading the verdict sees an anonymous control among several.
        if Self.rolesRequiringALabel.contains(role), Self.literalTextArgument(of: recursed) == nil {
            findings.append(
                ProbeLintFinding(node: Syntax(recursed), kind: .interactiveElementHasNoLabel(id: id))
            )
        }

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

    /// Records an author-written probe id, reporting a second use of one.
    ///
    /// An id is what every layer downstream matches on — `TreeDiff` pairs nodes
    /// by it, `DuplicateProbeIDRule` reports on it, Wave 5's baselines key on it
    /// — so two elements sharing one are merged into a single node for every
    /// consumer. The kernel catches this at runtime; catching it here is
    /// strictly stronger, because the compiler sees every `@Verifiable` view on
    /// every build while a runtime rule needs the view rendered in a scenario
    /// somebody remembered to write.
    ///
    /// The finding names the SECOND occurrence: the first is where the id was
    /// legitimately introduced, and pointing there sends the reader to a line
    /// that is not the mistake.
    private mutating func noteExplicitID(of expression: ExprSyntax) {
        guard let id = Self.explicitProbeID(in: expression) else { return }
        if !explicitIDs.insert(id).inserted {
            findings.append(
                ProbeLintFinding(node: Syntax(expression), kind: .duplicateExplicitID(id: id))
            )
        }
    }

    /// The literal id string of the `.verdictProbe` in this chain, if it has one.
    ///
    /// Returns `nil` for a non-literal id (`verdictProbe(someConstant)`), which
    /// is not a defect the macro can judge: the value is unknown at expansion
    /// time, and reporting a collision it cannot see — or staying silent about
    /// one it cannot rule out — are both honest only if the walk says nothing.
    static func explicitProbeID(in expression: ExprSyntax) -> String? {
        if let call = expression.as(FunctionCallExprSyntax.self) {
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                member.declName.baseName.text == "verdictProbe",
                let first = call.arguments.first, first.label == nil,
                let literal = first.expression.as(StringLiteralExprSyntax.self),
                literal.segments.count == 1,
                let segment = literal.segments.first?.as(StringSegmentSyntax.self)
            {
                return segment.content.text
            }
            return explicitProbeID(in: ExprSyntax(call.calledExpression))
        }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base {
            return explicitProbeID(in: base)
        }
        return nil
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
        updated.statements = rewriteStatements(closure.statements)
        return updated
    }

    /// Rewrites every statement in a view-builder block.
    ///
    /// Two statement shapes matter and only one of them is an expression. A bare
    /// `Text("x")` is a `CodeBlockItem` whose item IS an expression, and it is
    /// rewritten directly. An `if` or a `switch` inside a `@ViewBuilder` is a
    /// STATEMENT — the builder turns it into a view, but the syntax tree has no
    /// expression at that position — so a walk that handled only the first left
    /// every element in every branch unprobed. That is this product's worst
    /// defect shape and it is silent: the branch renders, the container's other
    /// probed children make the tree look observed, and `vacuous-verdict` (which
    /// fires only when NO probed node exists) cannot see it, so every rule
    /// reports PASS about content nobody instrumented.
    /// Internal rather than private: `#VerdictScenario` walks a trailing
    /// closure's statements directly and must enter through this same door. It
    /// had its own local map until Task 5, which carried the Task 4 conditional
    /// defect independently — one rule, two implementations, and neither test
    /// could see the other's copy.
    mutating func rewriteStatements(
        _ statements: CodeBlockItemListSyntax
    ) -> CodeBlockItemListSyntax {
        CodeBlockItemListSyntax(
            statements.map { item in
                var copy = item
                switch item.item {
                case .expr(let expression):
                    // The item's own leading trivia is what separates it from
                    // whatever precedes it — a newline and indentation, or the
                    // single space after a closure's `in`. `rewrite` returns a
                    // `.trimmed` expression, so that trivia must be carried
                    // across here or the two tokens are glued together:
                    // `{ row in` + `Text(…)` became `{ row inText(…)`, which is
                    // not Swift, so `@Verifiable` on any view containing a
                    // `ForEach` produced an expansion that could not compile.
                    let rewritten = rewrite(expression)
                    copy.item = .expr(
                        rewritten.with(\.leadingTrivia, expression.leadingTrivia)
                    )
                case .stmt(let statement):
                    copy.item = .stmt(rewriteStatement(statement))
                case .decl:
                    // A `let` inside a body the walk accepted cannot occur —
                    // `bodyResultExpression` requires a single-expression body —
                    // but a nested closure may hold one, and it holds no views.
                    break
                }
                return copy
            }
        )
    }

    /// Rewrites the view-builder branches a statement contains.
    ///
    /// `if` and `switch` are separate syntax nodes with no shared supertype to
    /// match once, so each is handled explicitly and a shape that is neither is
    /// returned untouched rather than guessed at.
    private mutating func rewriteStatement(_ statement: StmtSyntax) -> StmtSyntax {
        if let expressionStatement = statement.as(ExpressionStmtSyntax.self) {
            if let ifExpression = expressionStatement.expression.as(IfExprSyntax.self) {
                var updated = expressionStatement
                updated.expression = ExprSyntax(rewriteIf(ifExpression))
                return StmtSyntax(updated)
            }
            if let switchExpression = expressionStatement.expression.as(SwitchExprSyntax.self) {
                var updated = expressionStatement
                var copy = switchExpression
                copy.cases = SwitchCaseListSyntax(
                    switchExpression.cases.map { element in
                        guard case .switchCase(let switchCase) = element else { return element }
                        var caseCopy = switchCase
                        caseCopy.statements = rewriteStatements(switchCase.statements)
                        return .switchCase(caseCopy)
                    }
                )
                updated.expression = ExprSyntax(copy)
                return StmtSyntax(updated)
            }
        }
        return statement
    }

    /// Rewrites both arms of an `if`, following `else if` chains to their end.
    ///
    /// The `else` arm is itself an `IfExprSyntax` in an `else if`, so recursing
    /// through it is what keeps the third and later branches from being the only
    /// unprobed ones — a defect that a two-branch test cannot see.
    private mutating func rewriteIf(_ expression: IfExprSyntax) -> IfExprSyntax {
        var updated = expression
        updated.body.statements = rewriteStatements(expression.body.statements)
        switch expression.elseBody {
        case .codeBlock(let block):
            var copy = block
            copy.statements = rewriteStatements(block.statements)
            updated.elseBody = .codeBlock(copy)
        case .ifExpr(let nested):
            updated.elseBody = .ifExpr(rewriteIf(nested))
        case .none:
            break
        }
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

extension CodeBlockItemListSyntax {
    /// This list re-indented for interpolation into a generated template.
    ///
    /// The walk preserves each statement's leading trivia because INSIDE A
    /// CLOSURE it is load-bearing — it is the only token separating `in` from
    /// the first statement (`no.md` #24). At the TOP of a list being re-templated
    /// somewhere else it is the opposite: the template supplies the indent
    /// before the interpolation point, and the statements' original trivia was
    /// measured against a position they no longer occupy, so keeping it doubles
    /// the indentation of every statement after the first.
    ///
    /// So each statement is trimmed and re-separated by a single newline; the
    /// template's own interpolation indent then applies uniformly. Only the
    /// statements' OWN leading trivia is touched — trivia nested inside a
    /// statement (a closure's, where it matters) is untouched.
    var reindentedForTemplate: CodeBlockItemListSyntax {
        CodeBlockItemListSyntax(
            enumerated().map { index, item in
                item.with(\.leadingTrivia, index == 0 ? [] : .newline)
            }
        )
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
