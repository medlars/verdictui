// The consumer-facing half of the macro. Importing this module is what costs
// SwiftSyntax at build time, which is why it is a separate product from
// VerdictUIProbe (see Package.swift and Tests/test_macro_isolation.py).
@_exported import VerdictUIKernel
@_exported import VerdictUIProbe

/// Generates VerdictUI instrumentation for a SwiftUI view.
///
/// Attach it to a `View` struct and the macro adds `verdictProbedBody(into:)` —
/// the view's own `body` with a VerdictUI root installed — so a harness can
/// collect a semantic tree from it:
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
/// - Note: Wave 4 Task 1 generates the root wrapper. Attaching
///   `.verdictProbe(id:role:)` to individual elements — the part that makes the
///   tree *semantic* rather than a single node — is Task 2. Until then, pair the
///   macro with manual probes; they compose, and an explicit probe always wins
///   over a generated one.
///
/// - Important: `@Verifiable` requires a struct with a `body`. Both are reported
///   at the attachment site rather than as an error inside generated code, which
///   an author cannot see or fix.
@attached(member, names: named(verdictProbedBody))
public macro Verifiable() =
    #externalMacro(module: "VerdictUIMacros", type: "VerifiableMacro")
