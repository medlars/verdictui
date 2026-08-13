// VerdictUIProbe — Wave 9 Task 2: determinism hardening.
//
// A pixel baseline is a promise that this screen renders these exact bytes every
// time. Nothing in Task 1 checks that promise before making it, and a baseline
// written for a scenario that does NOT render identically twice is worse than no
// baseline at all: it fails at random later, on an unrelated commit, and the
// reader spends the afternoon looking for a regression in code that never
// changed.
//
// So the channel refuses. `DeterminismCheck.verify` renders the scenario twice
// and compares the bytes; a scenario that disagrees with itself is REFUSED with
// an error naming what to do about it, rather than given a baseline.
//
// The two renders go through the FULL host construction path rather than
// capturing one host twice. That is the whole point: a host renders `body(state:)`
// fresh on construction, so a `Date()`, a `UUID()`, a `Double.random` or an
// unpinned locale read is evaluated again — while capturing one existing host
// twice would re-encode a layout that was already fixed and report every scenario
// as deterministic. A check that cannot fail for its own reason is the defect
// this file exists to prevent, so it must not be the shape of the file itself.
import AppKit
import SwiftUI
import VerdictUIKernel

// MARK: - Result

/// What a double-render determinism check found.
public enum DeterminismResult: Sendable, Equatable {
    /// Both renders produced identical bytes. The capture is the shared result,
    /// so a caller that is about to write a baseline does not render a third time.
    case deterministic(PixelCapture)

    /// The two renders disagreed. Carries both hashes so the report can show that
    /// the difference is real rather than asserted, and the byte counts, which is
    /// usually enough to tell a changing string (sizes drift) from a changing
    /// colour (sizes often match).
    case nondeterministic(NondeterminismEvidence)

    /// True when the scenario may be given a pixel baseline.
    public var isDeterministic: Bool {
        if case .deterministic = self { return true }
        return false
    }
}

/// Why a scenario was refused a pixel baseline, in enough detail to fix it.
public struct NondeterminismEvidence: Sendable, Equatable {
    /// Scenario that disagreed with itself.
    public let scenarioName: String

    /// Content hash of the first render.
    public let firstHash: String

    /// Content hash of the second render.
    public let secondHash: String

    /// PNG byte count of the first render.
    public let firstByteCount: Int

    /// PNG byte count of the second render.
    public let secondByteCount: Int

    /// Backend both renders used. Recorded because the two backends answer
    /// different questions (see ``PixelBackend``), so a scenario that is
    /// nondeterministic under one is not thereby proven so under the other.
    public let backend: PixelBackend

    /// Actionable message naming the scenario and the usual causes.
    ///
    /// The causes are listed because "this scenario is nondeterministic" is a
    /// true statement that tells the reader nothing they can act on, and the
    /// answer is almost always one of a short list of unpinned inputs.
    public var advice: String {
        """
        '\(scenarioName)' rendered differently on two consecutive renders, so it \
        cannot be given a pixel baseline — one would fail at random on an \
        unrelated commit. First render \(firstByteCount) bytes (\(firstHash)), \
        second \(secondByteCount) bytes (\(secondHash)), backend \
        \(backend.rawValue). Usual causes: a `Date()` or `UUID()` evaluated in \
        `body`, a `.random` value, an animation still running at capture time, \
        or an input the host does not pin. Pin the value behind \
        `ScenarioState`, or verify this screen with semantic rules instead — \
        they do not require byte stability.
        """
    }
}

// MARK: - The check

/// Refuses a pixel baseline to any scenario that does not render identically
/// twice.
///
/// ```swift
/// switch try DeterminismCheck.verify(SettingsScreen(), viewport: viewport) {
/// case let .deterministic(capture):
///     try store.writeBaseline(capture)
/// case let .nondeterministic(evidence):
///     throw PixelBaselineError.refused(evidence)
/// }
/// ```
public enum DeterminismCheck {
    /// Render `scenario` twice and report whether the bytes agree.
    ///
    /// Each render constructs its own ``OracleHost`` and settles it, so the
    /// scenario's `body(state:)` is evaluated afresh both times — see this
    /// file's header for why capturing one host twice would answer the wrong
    /// question. Settling before capture matters for the same reason: an
    /// unsettled capture races the layout, so a perfectly deterministic screen
    /// caught mid-animation would be refused for the harness's timing rather
    /// than for its own content.
    ///
    /// - Parameters:
    ///   - scenario: what to render, twice.
    ///   - viewport: size to render at. Passed to both hosts, so a difference
    ///     can never be one of size.
    ///   - backend: which capture backend to use for both renders.
    /// - Throws: whatever ``OracleHost/capturePixels(backend:)`` or the settle
    ///   throws. A capture that cannot be produced is NOT reported as
    ///   nondeterminism — "the screen is unstable" and "the harness could not
    ///   look" are different findings and conflating them would send the reader
    ///   at the wrong subject.
    @MainActor
    public static func verify<Scenario: VerdictScenario>(
        _ scenario: Scenario,
        viewport: Size? = nil,
        backend: PixelBackend = .cacheDisplay
    ) async throws -> DeterminismResult {
        let first = try await renderOnce(scenario, viewport: viewport, backend: backend)
        let second = try await renderOnce(scenario, viewport: viewport, backend: backend)

        guard first.png != second.png else {
            return .deterministic(first)
        }
        return .nondeterministic(
            NondeterminismEvidence(
                scenarioName: first.scenarioName,
                firstHash: first.contentHash,
                secondHash: second.contentHash,
                firstByteCount: first.png.count,
                secondByteCount: second.png.count,
                backend: backend
            )
        )
    }

    /// Render twice through a caller-supplied host FACTORY and compare.
    ///
    /// The same check for callers that hold a way to build a host rather than a
    /// scenario value — `DemoScenarioEntry.makeHost(viewport:deadline:)` is the
    /// motivating case, since the catalog deliberately hides its scenario types
    /// behind a closure.
    ///
    /// The parameter is a FACTORY, not a host, and that is the contract: the
    /// factory must return a FRESH host per call, because a host renders
    /// `body(state:)` on construction and reusing one would re-encode a layout
    /// that was already fixed — reporting every scenario as deterministic
    /// regardless of what it does.
    @MainActor
    public static func verify(
        scenarioName: String,
        backend: PixelBackend = .cacheDisplay,
        makeHost: () -> OracleHost
    ) async throws -> DeterminismResult {
        let first = try await capture(from: makeHost(), backend: backend)
        let second = try await capture(from: makeHost(), backend: backend)

        guard first.png != second.png else {
            return .deterministic(first)
        }
        return .nondeterministic(
            NondeterminismEvidence(
                scenarioName: scenarioName,
                firstHash: first.contentHash,
                secondHash: second.contentHash,
                firstByteCount: first.png.count,
                secondByteCount: second.png.count,
                backend: backend
            )
        )
    }

    /// One full construct-settle-capture cycle.
    @MainActor
    private static func renderOnce<Scenario: VerdictScenario>(
        _ scenario: Scenario,
        viewport: Size?,
        backend: PixelBackend
    ) async throws -> PixelCapture {
        try await capture(
            from: OracleHost(scenario: scenario, viewport: viewport),
            backend: backend
        )
    }

    /// Settle a host, then capture it.
    ///
    /// Spelled once and shared by both `verify` overloads, so the two cannot
    /// drift into settling differently — a difference in settling would show up
    /// as a difference in DETERMINISM, which is the one thing this file must
    /// never misattribute.
    @MainActor
    private static func capture(
        from host: OracleHost,
        backend: PixelBackend
    ) async throws -> PixelCapture {
        // Settle rather than capture immediately: a mid-layout capture would
        // make the harness's own timing look like the scenario's instability.
        _ = try await host.currentTree()
        return try host.capturePixels(backend: backend)
    }
}

// MARK: - Refusal

/// Raised when a caller asks for a pixel baseline the channel will not write.
public enum PixelBaselineError: Error, CustomStringConvertible, Equatable {
    /// The scenario failed its double-render determinism check.
    case refused(NondeterminismEvidence)

    public var description: String {
        switch self {
        case let .refused(evidence):
            return evidence.advice
        }
    }
}
