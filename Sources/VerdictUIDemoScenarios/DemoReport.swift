// VerdictUIDemoScenarios — the deliberately bug-rich catalog.
//
// Wave 2 Task 5: the whole body of the `VerdictUIDemo` executable, living in the
// library rather than in the executable target. SwiftPM test targets cannot
// import an executable target, so a `main` with logic in it is a `main` nothing
// can assert on; keeping the logic here makes the executable one statement long
// and its output testable in-process, with no subprocess to spawn and no output
// to scrape.
import Foundation
import VerdictUIKernel
import VerdictUIProbe

/// Renders every demo scenario, lints it, and reports the verdicts.
///
/// This is the product's smallest end-to-end path — scenario in, JSON verdict
/// out — and the material the README's demo is recorded from, so the output is
/// shaped for a reader: the pinned wire format from
/// `contracts/verdict-schema.json`, pretty-printed with sorted keys, and no
/// embedded trees (``RuleEngine/run(rules:on:context:includeTree:)`` defaults
/// `includeTree` to false because a tree dwarfs the findings it explains).
@MainActor
public enum DemoReport {
    /// One verdict per scenario in ``DemoScenarios/all``, in catalog order.
    ///
    /// Each scenario is rendered at its own ``DemoScenarioEntry/recommendedViewport``
    /// — for ``OffscreenButtonScenario`` the viewport *is* the planted defect's
    /// reference frame — and linted with ``RuleEngine/standardRules`` under
    /// ``LintContext/macOS(viewport:scenario:)``, whose viewport is taken from
    /// the tree's own root frame rather than from the requested size, so a host
    /// that clamped or rounded is linted against the rectangle it actually used.
    ///
    /// ``Verdict/Timing/settleMs`` is filled in with the wall-clock cost of
    /// ``OracleHost/currentTree()`` for that scenario: it is what SLO 1 (p95 <
    /// 50 ms) is measured against, and it is the reason the output is not
    /// byte-stable between runs. Neither is ``Verdict/timestamp``, by design.
    ///
    /// - Throws: whatever ``OracleHost/currentTree()`` throws — a scenario that
    ///   cannot be settled is reported as a failure of the run, not smuggled
    ///   into the output as an empty verdict. Failure is fail-fast and total on
    ///   purpose: verdicts already computed for earlier scenarios are discarded,
    ///   because the run's contract is "one JSON document describing the whole
    ///   catalog, or a thrown error naming the scenario that broke it" — a
    ///   partial document would parse cleanly and read as a smaller catalog.
    ///   `OracleHostError`'s description carries the scenario name, so the
    ///   caller can always say *which* scenario failed. (`no.md` entry 9.)
    ///
    /// - Parameter deadline: settle budget per scenario, forwarded to each
    ///   host. The default is the production value; tests hand in `0` to walk
    ///   the failure path without waiting out a real timeout.
    public static func verdicts(
        deadline: TimeInterval = OracleHost.defaultDeadline
    ) async throws -> [Verdict] {
        var results: [Verdict] = []
        for entry in DemoScenarios.all {
            let host = entry.makeHost(deadline: deadline)
            let started = ContinuousClock.now
            let tree = try await host.currentTree()
            let settle = ContinuousClock.now - started
            var verdict = RuleEngine.run(
                rules: RuleEngine.standardRules,
                on: tree,
                context: .macOS(viewport: tree.frame, scenario: host.scenarioName)
            )
            verdict.timing.settleMs = settle.milliseconds
            results.append(verdict)
        }
        return results
    }

    /// ``verdicts()`` as a JSON array, one element per scenario.
    ///
    /// An array rather than newline-delimited objects: the whole document
    /// parses in one call, so the executable's smoke test can assert the output
    /// is valid JSON rather than valid-JSON-per-line, and a reader watching the
    /// demo sees where the run starts and ends.
    ///
    /// - Parameter deadline: forwarded to ``verdicts(deadline:)``. Present for
    ///   the same reason it is there — this is the function the executable
    ///   actually calls, so a seam that stopped at `verdicts` would leave the
    ///   shipped path's failure branch reachable only by waiting out a real
    ///   timeout.
    ///
    /// - Throws: an encoding failure, or anything ``verdicts(deadline:)``
    ///   throws. Nothing is returned partially: a throw here means no document,
    ///   not a truncated one.
    public static func renderJSON(
        deadline: TimeInterval = OracleHost.defaultDeadline
    ) async throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(try await verdicts(deadline: deadline))
        // The encoder produces UTF-8 by contract, so the only way this fails is
        // a bug in Foundation; an empty string would be a silent one.
        guard let json = String(data: data, encoding: .utf8) else {
            throw DemoReportError.outputWasNotUTF8(byteCount: data.count)
        }
        return json
    }
}

/// What ``DemoReport`` throws that is its own fault rather than a scenario's.
public enum DemoReportError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The encoded verdicts were not decodable as UTF-8.
    case outputWasNotUTF8(byteCount: Int)

    public var description: String {
        switch self {
        case .outputWasNotUTF8(let byteCount):
            "the encoded verdict report (\(byteCount) bytes) was not valid UTF-8"
        }
    }
}

extension Duration {
    /// This duration in milliseconds, so ``Verdict/Timing/settleMs`` is stated
    /// in the same unit the kernel states ``Verdict/Timing/evaluateMs`` in.
    ///
    /// The kernel has the same three lines in `SchemaVersion.swift` and they are
    /// deliberately not shared: that copy is internal, and widening a numeric
    /// conversion helper into the kernel's public API — the surface pinned by
    /// `contracts/verdict-schema.json` — to save three lines in a demo target
    /// would be the wrong trade.
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
    }
}
