import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Implementation of `@Verifiable`.
///
/// Generates one member: `verdictProbedBody`, a COPY of the view's `body` with
/// `.verdictProbe(id:role:text:)` attached to every recognised element (see
/// ``BodyProbeWalk``) and `.verdictRoot(into:)` installed at the top. The view's
/// own `body` is never rewritten, so a `@Verifiable` view renders identically in
/// a real app — a member macro cannot replace a member anyway, and generating a
/// second `body` would be a redeclaration error.
///
/// Everything this file owns beyond that is *diagnostics*, which is the part
/// that decides whether a misapplied macro is legible: all three rejections are
/// reported at the attachment site, never as an error deep inside generated code
/// the author cannot see or edit.
extension VerifiableMacro: ExtensionMacro {
    /// Adds the `VerifiableView` conformance that makes the two macros compose.
    ///
    /// Separate from the member expansion because a member macro cannot add a
    /// conformance, and the conformance is the whole mechanism: it is what
    /// `verdictProbing(_:)`'s constrained overload keys on, so a scenario can
    /// render a custom view's PROBED content without the macro having to know
    /// at expansion time whether that view is verifiable (it cannot — a macro
    /// runs on syntax, before type checking).
    ///
    /// Emits nothing for a declaration the member expansion rejected. Adding a
    /// conformance whose requirement the member expansion declined to generate
    /// would replace one clear diagnostic at the attachment site with an
    /// unsatisfied-requirement error the author cannot act on.
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self),
            structDecl.hasBodyMember,
            structDecl.bodyResultExpression != nil
        else {
            return []
        }
        return [try ExtensionDeclSyntax("extension \(type): VerifiableView {}")]
    }
}

public struct VerifiableMacro: MemberMacro {
    /// Types `@Verifiable` accepts. A macro attached to an `enum` or an
    /// `actor` must say so at the attachment site — the alternative is an
    /// expansion that fails to compile deeper in generated code the author
    /// cannot see, which is the worst diagnostic a macro can produce.
    private static let supportedKeyword = "struct"

    /// - Parameter protocols: conformances the compiler wants this expansion to
    ///   satisfy. Unused: `@Verifiable` is declared `@attached(member)` with no
    ///   `conformances:` clause, so the compiler never asks it to supply one and
    ///   this always arrives empty. The parameter is present because the
    ///   `conformingTo:`-less overload is deprecated in SwiftSyntax 603 — and
    ///   under `-warnings-as-errors` a deprecation is a build failure, so the
    ///   shorter spelling does not compile here at all.
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: VerdictMacroDiagnostic.notAStruct(
                        found: declaration.kindDescription
                    )
                )
            )
            return []
        }

        guard structDecl.hasBodyMember else {
            context.diagnose(
                Diagnostic(node: node, message: VerdictMacroDiagnostic.noBodyMember)
            )
            return []
        }

        guard let bodyExpression = structDecl.bodyResultExpression else {
            // A body the walk cannot rewrite is reported rather than silently
            // half-handled. Generating an unprobed passthrough would be the
            // worse outcome: the view compiles, produces a tree with a root and
            // nothing under it, and every rule reports PASS on a screen nobody
            // instrumented — a false green is this product's worst failure.
            context.diagnose(
                Diagnostic(node: node, message: VerdictMacroDiagnostic.bodyIsNotASingleExpression)
            )
            return []
        }

        // The walk operates on a COPY of the body's expression, which is what
        // makes `verdictProbedBody` the probed twin rather than a passthrough.
        // Calling the view's own `body` here instead would return the unwalked
        // view, so the macro would buy a root and nothing under it.
        var walk = BodyProbeWalk(typeName: structDecl.name.text)
        // `.trimmed` on each end, and nothing more ambitious than that.
        //
        // The expression is LIFTED out of `body`, so its interior lines carry
        // indentation measured against their old position and the generated
        // member inherits it. `SwiftBasicFormat.formatted()` does not fix this
        // and was removed after being measured rather than assumed: it only
        // supplies trivia where trivia is ABSENT, so it indented the walk's
        // freshly-built probe lines and left the original closure's closing
        // brace exactly as it found it. Stripping all trivia first and then
        // formatting produces FLAT output — the formatter adds no nesting depth
        // either. There is no re-indent facility in SwiftSyntax to reach for.
        //
        // So the interior indentation of a multi-line body is inherited, and
        // that is a cosmetic wart in the "Expand Macro" buffer, where Xcode
        // applies its own formatting anyway. Pinned by the snapshot tests as
        // what it IS rather than papered over, so a future SwiftSyntax that
        // does re-indent shows up as a test failure to be looked at, not as
        // silent drift.
        let probedBody = walk.rewrite(bodyExpression).trimmed

        // Compile-time lint (Wave 4 Task 5). The walk is the only pass that sees
        // every element together with its author-written ids and labels, so it
        // collects findings and they are diagnosed here, where the context is.
        //
        // Emitted even when a finding is an ERROR, and the expansion still
        // proceeds: a duplicate id is a real defect but the generated body is
        // otherwise correct, and returning `[]` here would replace one clear
        // diagnostic with a cascade of "no member 'verdictProbedBody'" errors
        // at every call site — the deeper-in-generated-code failure this file's
        // other diagnostics exist to avoid.
        for finding in walk.findings {
            context.diagnose(finding.diagnostic)
        }

        // `verdictProbedBody` rather than a rewritten `body`: a member macro
        // cannot replace an existing member, and generating a second `body`
        // would be a redeclaration error. The harness reaches the probed tree
        // through this member; the view's own `body` stays untouched, so a
        // `@Verifiable` view renders identically in a real app.
        return [
            """
            /// The view's `body`, probed, with the VerdictUI root installed.
            ///
            /// Generated by `@Verifiable`. Inert until a `VerdictTreeSink` is
            /// attached, so this is a normal view everywhere else.
            @ViewBuilder
            func verdictProbedBody(into sink: VerdictTreeSink) -> some View {
                \(probedBody).verdictRoot(into: sink)
            }
            """,
            """
            /// The view's `body`, probed, with NO root installed.
            ///
            /// Generated by `@Verifiable`, and this is the member that makes the
            /// two macros COMPOSE. `verdictProbedBody(into:)` installs a root,
            /// and nesting one root inside another is unsupported — the inner
            /// viewport reaches the outer collector and every frame is then
            /// measured against the wrong rectangle. A view rendered INSIDE a
            /// scenario is already under `OracleHost`'s root, so it needs the
            /// probed content and nothing else.
            @ViewBuilder
            var verdictProbedContent: some View {
                \(probedBody)
            }
            """
        ]
    }
}

extension StructDeclSyntax {
    /// The expression the type's `body` produces, for the macro to walk.
    ///
    /// Found by name rather than by resolving `View` conformance, because a
    /// macro runs before conformances are checked and cannot see whether the
    /// type is a `View` — the conformance may even arrive from an extension in
    /// another file. Name-matching is therefore the strongest signal available
    /// at expansion time, and it is honest about that: a `body` that is not a
    /// view's `body` is accepted here and rejected by the compiler downstream.
    ///
    /// Returns `nil` when there is no `body`, and also when the `body` is not a
    /// single expression the walk can rewrite (a multi-statement body with
    /// `let`s and control flow). `nil` therefore has two meanings, which the
    /// caller must keep distinct — see ``VerdictMacroDiagnostic``.
    var bodyResultExpression: ExprSyntax? {
        guard let binding = bodyBinding else { return nil }
        return Self.resultExpression(of: binding)
    }

    /// Whether the type declares a `body` at all.
    ///
    /// Separate from ``bodyResultExpression`` because "no body" and "a body the
    /// walk cannot rewrite" are different author mistakes that need different
    /// messages; collapsing them into one `nil` would tell someone with a
    /// perfectly good multi-statement body to "add the view's body".
    var hasBodyMember: Bool { bodyBinding != nil }

    private var bodyBinding: PatternBindingSyntax? {
        for member in memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings
            where binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "body" {
                return binding
            }
        }
        return nil
    }

    /// The single expression a computed property's accessor yields.
    ///
    /// Handles both spellings the compiler treats as one declaration: the
    /// implicit-getter `var body: some View { expr }` and the explicit
    /// `var body: some View { get { expr } }`. They are the same to the type
    /// checker and different syntax trees, so a walk that read only the first
    /// would silently decline to probe every view written the other way
    /// (lesson 256 — a detector recognises the spelling its author happened to
    /// write, and reports nothing about the rest).
    private static func resultExpression(of binding: PatternBindingSyntax) -> ExprSyntax? {
        switch binding.accessorBlock?.accessors {
        case .getter(let statements):
            return singleExpression(of: statements)
        case .accessors(let accessors):
            for accessor in accessors where accessor.accessorSpecifier.tokenKind == .keyword(.get) {
                guard let body = accessor.body else { return nil }
                return singleExpression(of: body.statements)
            }
            return nil
        case .none:
            return nil
        }
    }

    private static func singleExpression(of statements: CodeBlockItemListSyntax) -> ExprSyntax? {
        guard statements.count == 1 else { return nil }
        return statements.first?.item.as(ExprSyntax.self)
    }
}

extension DeclGroupSyntax {
    /// A human-readable kind name for diagnostics, carrying its own article
    /// ("an enum", "a class", …).
    ///
    /// `Syntax.kind` renders as `enumDecl`, which leaks the parser's vocabulary
    /// into a message an app author reads, so the common shapes are named
    /// directly and anything else degrades to a generic word rather than to
    /// something misleading.
    ///
    /// The article is part of the value rather than a literal at the
    /// interpolation site because two of these kinds begin with a vowel: a
    /// hardcoded "a" produces "this is a enum" and "this is a actor". Choosing
    /// per-kind here is exact, where any rule applied at the call site would be
    /// guessing from spelling.
    var kindDescription: String {
        switch self {
        case is EnumDeclSyntax: return "an enum"
        case is ClassDeclSyntax: return "a class"
        case is ActorDeclSyntax: return "an actor"
        case is ProtocolDeclSyntax: return "a protocol"
        case is ExtensionDeclSyntax: return "an extension"
        default: return "a declaration"
        }
    }
}

/// Diagnostics `@Verifiable` can emit at its attachment site.
///
/// Spelled as a value type with an explicit `messageID` rather than assembled
/// inline, so the *text* an author sees is a testable constant. A macro whose
/// diagnostics are string literals at the throw site cannot be asserted on
/// without duplicating those literals in the test, which pins the typo rather
/// than the meaning.
enum VerdictMacroDiagnostic: DiagnosticMessage {
    case notAStruct(found: String)
    case noBodyMember
    case bodyIsNotASingleExpression

    var message: String {
        switch self {
        case .notAStruct(let found):
            // `found` carries its own article — see `kindDescription`.
            return """
                '@Verifiable' can only be attached to a struct, but this is \(found). \
                SwiftUI views are structs; if this type is a view, declare it as one.
                """
        case .noBodyMember:
            return """
                '@Verifiable' needs a 'body' to wrap, and this type declares none. \
                Add the view's 'body', or remove the attribute.
                """
        case .bodyIsNotASingleExpression:
            return """
                '@Verifiable' can only probe a 'body' that is a single expression, and \
                this one is not. Move the statements into a computed property or a \
                subview, or probe the elements by hand with '.verdictProbe(_:role:)'.
                """
        }
    }

    var severity: DiagnosticSeverity { .error }

    var diagnosticID: MessageID {
        switch self {
        case .notAStruct:
            return MessageID(domain: "VerdictUIMacros", id: "notAStruct")
        case .noBodyMember:
            return MessageID(domain: "VerdictUIMacros", id: "noBodyMember")
        case .bodyIsNotASingleExpression:
            return MessageID(domain: "VerdictUIMacros", id: "bodyIsNotASingleExpression")
        }
    }
}
