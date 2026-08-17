// VerdictUIAppKit — the runner a consumer's own executable uses.
//
// The bridge from `AppKitRenderer` (a Swift API) to the CLI (a process).
//
// Why a runner rather than dynamic loading: an `NSView` subclass exists only in
// the binary that compiled it. It cannot cross a process boundary, be
// reconstructed from JSON, or be dlopened without coupling the installed CLI to
// the consumer's exact toolchain. So the consumer compiles a five-line
// executable that links this target and names its views; the CLI runs that
// executable and judges the tree it prints. That is the same mechanism
// `ProjectScenarios` already uses for SwiftUI scenarios, and it needs no plugin
// ABI, no dlopen, and no version handshake.
import AppKit
import Foundation
import VerdictUIKernel

/// A named AppKit view a consumer wants judged.
///
/// The builder is a closure rather than a stored `NSView` because constructing
/// a view is not free and a catalog of twenty screens should build the one that
/// was asked for, not all twenty.
@MainActor
public struct AppKitSubject {
    /// Name the caller asks for, and the name the verdict is filed under.
    public let name: String
    /// Size to lay out at, or `nil` to keep the view's own frame.
    public let viewport: CGSize?
    /// Builds the view. Called at most once per run.
    public let build: @MainActor () -> NSView

    public init(
        _ name: String,
        viewport: CGSize? = nil,
        build: @escaping @MainActor () -> NSView
    ) {
        self.name = name
        self.viewport = viewport
        self.build = build
    }

    /// A subject backed by a view controller — the common case, since an AppKit
    /// screen is normally an `NSViewController`.
    public static func controller(
        _ name: String,
        viewport: CGSize? = nil,
        build: @escaping @MainActor () -> NSViewController
    ) -> AppKitSubject {
        // The controller is held by the closure for the duration of the render:
        // `controller.view` does not retain its controller, so returning the
        // view alone would let the controller deallocate and take any
        // controller-owned subviews with it. Binding it to a local inside the
        // closure keeps it alive exactly as long as the view is being walked.
        AppKitSubject(name, viewport: viewport) {
            let controller = build()
            // Touching `.view` IS the load — `loadViewIfNeeded()` would be the
            // clearer spelling but is macOS 14+, and ADR 2026-006 fixes the
            // package floor at macOS 13 because a raised floor locks consumers
            // out with an error that names the product rather than the API.
            return controller.view
        }
    }
}

/// The entry point a consumer's runner executable calls.
///
/// ```swift
/// // Sources/VerdictUIRunner/main.swift — the whole file.
/// import VerdictUIAppKit
/// import MyAppUI
///
/// AppKitTreeRunner.main(subjects: [
///     .controller("startup-manager") { StartupManagerViewController() },
///     .controller("trust-scores", viewport: CGSize(width: 900, height: 600)) {
///         TrustScoresViewController()
///     },
/// ])
/// ```
///
/// Two verbs, matching what the CLI needs and nothing more:
///
/// - `list` — print every subject name, one per line.
/// - `render <name>` — print the subject's semantic tree as JSON on stdout.
///
/// Exit codes follow the tool's three-valued contract: `0` succeeded, `2` could
/// not produce a tree. There is no `1`, because a runner does not judge — it
/// produces the tree the kernel judges, and conflating "I could not build your
/// view" with "your view is wrong" is the exact confusion that contract exists
/// to prevent.
@MainActor
public enum AppKitTreeRunner {

    /// Exit codes this runner uses. Deliberately the same numbers, and the same
    /// meanings, as `verdictui`'s own — a runner that invented its own mapping
    /// would make the CLI's exit code a translation of a translation.
    public enum Status: Int32 {
        /// The tree was produced.
        case ok = 0
        /// No tree could be produced: unknown subject, bad arguments.
        case couldNotProduce = 2
    }

    /// Run the runner against the process's own arguments and exit.
    ///
    /// Terminates the process, which is what a `main.swift` wants. Use
    /// ``run(arguments:subjects:output:)`` to drive the same logic from a test
    /// without ending the test process.
    ///
    /// ### Call this from `main.swift` via ``launch(subjects:)``, not directly
    ///
    /// Top-level code in `main.swift` is NOT main-actor-isolated, so calling
    /// this `@MainActor` method there fails to compile under Swift 6 with
    /// "call to main actor-isolated static method in a synchronous nonisolated
    /// context". Measured against a real consumer package before this note
    /// existed: three errors, none of which name the fix. ``launch(subjects:)``
    /// is nonisolated and does the hop itself.
    public static func main(subjects: [AppKitSubject]) -> Never {
        exit(runMain(subjects: subjects).rawValue)
    }

    /// ``main(subjects:)`` without the `exit` — the process's own arguments,
    /// written to the process's own streams, returning the status instead of
    /// terminating. Split out so ``launch(subjects:)`` can exit from the main
    /// queue, and so a test can drive the argv path without ending itself.
    static func runMain(subjects: [AppKitSubject]) -> Status {
        run(
            arguments: Array(CommandLine.arguments.dropFirst()),
            subjects: subjects
        ) { FileHandle.standardOutput.write(Data($0.utf8)) } onError: {
            FileHandle.standardError.write(Data($0.utf8))
        }
    }

    /// What a consumer's `main.swift` calls. Nonisolated, so it compiles in
    /// top-level code; hops to the main actor itself, because AppKit layout
    /// requires the main thread and a consumer should not have to know that.
    ///
    /// ```swift
    /// // Sources/VerdictUIRunner/main.swift — the whole file.
    /// import VerdictUIAppKit
    /// import MyAppUI
    ///
    /// AppKitTreeRunner.launch(subjects: [
    ///     .controller("startup-manager") { StartupManagerViewController() },
    /// ])
    /// ```
    ///
    /// `subjects` is an autoclosure evaluated ON the main actor: an
    /// `AppKitSubject` array cannot be BUILT off it (`AppKitSubject` is
    /// `@MainActor`), so taking it as a plain parameter would move the same
    /// compile error one line up and solve nothing — measured against a real
    /// consumer package, which is where this whole entry point came from.
    public nonisolated static func launch(
        subjects: @autoclosure @escaping @Sendable @MainActor () -> [AppKitSubject]
    ) -> Never {
        // `DispatchQueue.main.async` + `dispatchMain()` rather than a `Task`:
        // the runner must EXIT with a status code, and a detached task races the
        // process teardown. This blocks the calling thread forever and lets the
        // main queue run the body, which ends in `exit`.
        //
        // The block is `@Sendable` and the hop is expressed with an unsafe
        // `MainActor` assumption rather than `MainActor.assumeIsolated`, which
        // is macOS 14+ and would raise the package floor that ADR 2026-006
        // fixes at 13. The assumption is SOUND here and not merely convenient:
        // the block is submitted to `DispatchQueue.main`, which IS the main
        // actor's executor, so it cannot run anywhere else.
        DispatchQueue.main.async {
            let status = MainActorAssumption.run { runMain(subjects: subjects()) }
            exit(status.rawValue)
        }
        dispatchMain()
    }

    /// The runner's whole behaviour, as a function of its arguments.
    ///
    /// Injectable output so a test asserts on what was written rather than
    /// spawning a process — the same reason `VerdictOutput.OutputSink` exists on
    /// the CLI side.
    @discardableResult
    public static func run(
        arguments: [String],
        subjects: [AppKitSubject],
        output: (String) -> Void,
        onError: (String) -> Void = { _ in }
    ) -> Status {
        guard let verb = arguments.first else {
            onError("usage: <runner> list | render <subject>\n")
            return .couldNotProduce
        }

        switch verb {
        case "list":
            output(subjects.map(\.name).joined(separator: "\n") + "\n")
            return .ok

        case "render":
            guard arguments.count > 1 else {
                onError("render requires a subject name\n")
                return .couldNotProduce
            }
            let name = arguments[1]
            guard let subject = subjects.first(where: { $0.name == name }) else {
                onError(
                    "unknown subject '\(name)' — known: "
                        + "\(subjects.map(\.name).joined(separator: ", "))\n")
                return .couldNotProduce
            }
            let tree = AppKitRenderer.tree(for: subject.build(), viewport: subject.viewport)
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(tree)
                output((String(data: data, encoding: .utf8) ?? "") + "\n")
                return .ok
            } catch {
                onError("could not encode the tree: \(error)\n")
                return .couldNotProduce
            }

        default:
            onError("unknown verb '\(verb)' — expected list or render\n")
            return .couldNotProduce
        }
    }
}

/// Runs a main-actor-isolated body from code the compiler cannot see is already
/// on the main thread.
///
/// Exists ONLY because `MainActor.assumeIsolated` is macOS 14+ and ADR 2026-006
/// fixes this package's floor at macOS 13 — a raised floor locks consumers out
/// with an error naming the product rather than the API. The single call site is
/// inside a `DispatchQueue.main.async` block, which is the main actor's own
/// executor, so the assumption is a statement about where the code runs rather
/// than a hope.
///
/// Deliberately not `public`, and a second call site needs the same argument
/// made again: an unsafe hop from a context that is not genuinely the main
/// queue is a data race the compiler has been told not to look for.
enum MainActorAssumption {
    static func run<T>(_ body: @MainActor () -> T) -> T {
        withoutActuallyEscaping(body) { escaping in
            unsafeBitCast(escaping, to: (() -> T).self)()
        }
    }
}
