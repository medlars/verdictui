// The consumer-facing half of the macro. Importing this module is what costs
// SwiftSyntax at build time, which is why it is a separate product from
// VerdictUIProbe (see Package.swift and Tests/test_macro_isolation.py).
@_exported import VerdictUIKernel
@_exported import VerdictUIProbe

/// Generates VerdictUI instrumentation for a SwiftUI view.
///
/// Attach it to a `View` struct and the macro adds `verdictProbedBody(into:)` —
/// the view's `body`, with `.verdictProbe(id:role:text:)` attached to every
/// recognised element and a VerdictUI root installed — so a harness can collect
/// a semantic tree from it:
///
/// ```swift
/// @Verifiable
/// struct SettingsRow: View {
///     var body: some View {
///         HStack {
///             Text("Notifications")
///             Toggle("", isOn: $enabled)
///         }
///     }
/// }
/// ```
///
/// The view is unchanged everywhere else: `body` is not rewritten, and the
/// generated member is inert until a ``VerdictTreeSink`` is attached, so a
/// `@Verifiable` view renders identically in an app and in a preview.
///
/// Generated ids are derived from source structure — `SettingsRow.text.0`,
/// `SettingsRow.toggle.0` — so they are stable across runs and readable in a
/// finding. `Text`, `Button`, `Toggle`, `TextField`, `SecureField`, `Image` and
/// `List` are recognised.
///
/// - Note: An explicit `.verdictProbe(_:role:)` always wins: an element that
///   already carries one is left exactly as written, so the macro and manual
///   probes compose. Reach for a manual probe when you want a stable id of your
///   own choosing, or a role the walk cannot infer.
///
/// - Note: The walk sees *spelling*, not types — a macro runs before type
///   checking. A custom subview (`MyRow()`) is therefore opaque and is not
///   probed; annotate it with `@Verifiable` too and the two compose. An element
///   held in a `let` and referenced later is likewise invisible.
///
/// - Important: `@Verifiable` requires a struct with a `body`, and that `body`
///   must be a single expression. All three are reported at the attachment site
///   rather than as an error inside generated code, which an author cannot see
///   or fix.
@attached(member, names: named(verdictProbedBody))
public macro Verifiable() =
    #externalMacro(module: "VerdictUIMacros", type: "VerifiableMacro")
