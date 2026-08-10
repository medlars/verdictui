import SwiftDiagnostics
import SwiftSyntax

/// A verifiability defect `BodyProbeWalk` noticed, with the node that carries it.
///
/// The walk collects these rather than diagnosing them, because it holds no
/// `MacroExpansionContext` — it is a pure syntax-to-syntax transform, which is
/// what lets `assertMacroExpansion` and both macros drive it identically. The
/// macro that owns the context converts each finding at the node it names.
///
/// Every finding points at the OFFENDING ELEMENT rather than at the attribute.
/// That is the opposite of ``VerdictMacroDiagnostic``, which reports whole-
/// declaration rejections at the attachment site, and the difference is
/// deliberate: those say "this macro does not apply here", where these say
/// "this line is the problem" and the author needs the line.
struct ProbeLintFinding {
    let node: Syntax
    let kind: Kind

    enum Kind {
        /// Two elements in one view were given the same author-written id.
        case duplicateExplicitID(id: String)
        /// An interactive element the verdict can locate but cannot name.
        case interactiveElementHasNoLabel(id: String)
    }
}

extension ProbeLintFinding.Kind: DiagnosticMessage {
    var message: String {
        switch self {
        case .duplicateExplicitID(let id):
            return """
                Two elements in this view both use the probe id '\(id)'. Ids must be \
                unique within a view: TreeDiff matches nodes by id and a baseline keys \
                on it, so a collision silently merges the two elements. Give this one a \
                different id.
                """
        case .interactiveElementHasNoLabel(let id):
            return """
                This button has no label the verdict can name it by, so it is probed as \
                '\(id)' with no text. Add '.verdictProbe("\(id)", role: .button, \
                text: "…")' with the label a user would read, or give the button a \
                string label.
                """
        }
    }

    /// A duplicate id is an error; a missing label is a warning.
    ///
    /// The split is not a severity preference, it is about whether any reading
    /// of the code makes the shape intentional. Two elements sharing an id are
    /// merged for every consumer downstream and no author means that. A button
    /// with an image label is ordinary, correct SwiftUI that renders and is
    /// verifiable in every respect except its name — refusing to compile it
    /// would make `@Verifiable` reject working code, which is how a tool sold
    /// on adoption gets deleted rather than fixed.
    var severity: DiagnosticSeverity {
        switch self {
        case .duplicateExplicitID: return .error
        case .interactiveElementHasNoLabel: return .warning
        }
    }

    var diagnosticID: MessageID {
        switch self {
        case .duplicateExplicitID:
            return MessageID(domain: "VerdictUIMacros", id: "duplicateExplicitID")
        case .interactiveElementHasNoLabel:
            return MessageID(domain: "VerdictUIMacros", id: "interactiveElementHasNoLabel")
        }
    }
}

/// The fix-it offered alongside a warning.
///
/// Spelled as a type with its own `fixItID` rather than assembled inline, for
/// the same reason the diagnostics are: the text an author sees is a testable
/// constant, and a message written as a literal at the throw site can only be
/// asserted by duplicating the literal in the test, which pins the typo rather
/// than the meaning.
struct ProbeLintFixIt: FixItMessage {
    let message: String
    let fixItID: MessageID

    static let addLabelledProbe = ProbeLintFixIt(
        message: "Add an explicit probe carrying the button's label",
        fixItID: MessageID(domain: "VerdictUIMacros", id: "addLabelledProbe")
    )
}

extension ProbeLintFinding {
    /// This finding as a `Diagnostic` pointing at the element it concerns.
    ///
    /// The fix-it INSERTS a probe rather than rewriting one, and it deliberately
    /// leaves the label as an empty string for the author to fill: the macro
    /// does not know what the button says, and a fix-it that guessed — "Button",
    /// or the image's asset name — would write a plausible wrong label into the
    /// one field a human reads to identify the control. An empty string is
    /// visibly incomplete; a wrong one is not.
    var diagnostic: Diagnostic {
        switch kind {
        case .duplicateExplicitID:
            return Diagnostic(node: node, message: kind)
        case .interactiveElementHasNoLabel(let id):
            let probed: ExprSyntax =
                "\(raw: node.trimmedDescription).verdictProbe(\(raw: id.quotedForSource), role: .button, text: \"\")"
            return Diagnostic(
                node: node,
                message: kind,
                fixIt: FixIt(
                    message: ProbeLintFixIt.addLabelledProbe,
                    changes: [.replace(oldNode: node, newNode: Syntax(probed))]
                )
            )
        }
    }
}
