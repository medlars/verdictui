import SwiftUI
import VerdictUIKernel

@testable import VerdictUIProbe

/// A layout that is STATIC until tapped, then never reaches a fixed point.
///
/// The distinction from ``PerpetualMotionScenario`` is the whole reason this
/// exists, and it is easy to get wrong. A scenario that moves from the start
/// cannot reach `perform`'s settle-timeout branch at all: the `currentTree()`
/// capture that runs BEFORE the act carries its own 3 s deadline, throws
/// against a layout that never settles, and takes the host-error path instead.
/// A test written against that fixture measures 3 s of capture cost while
/// believing it measures a settle — measured, not assumed: 3002 ms reported
/// against a 120 ms budget (`no.md` #12).
///
/// Being static until the act inverts that: the first capture settles cleanly,
/// so only the settle AFTER the act runs to the caller's deadline, which is the
/// one path where `settleMs` could have been a budget rather than a
/// measurement.
@MainActor
final class LateMotionModel: ObservableObject {
    /// Drives the frame width. Only its CHANGING matters, not its value.
    @Published var phase = 0

    private var timer: Timer?

    /// Begin moving. Idempotent — a second tap must not stack timers, which
    /// would make the motion rate depend on how often the fixture was acted on.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.002, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.phase += 1 }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stop moving. Every test that starts this MUST stop it: a live run-loop
    /// timer outlives the test that made it and perturbs whatever measures
    /// wall-clock next, which is exactly the cross-test contamination that
    /// makes a timing suite flake for reasons no one can attribute.
    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// Hosts ``LateMotionModel`` behind a tap that starts the motion.
struct LateMotionScenario: VerdictScenario {
    /// The single probe, named once so a test cannot drift from the view.
    static let probeID = "mover"

    /// Viewport that fits the widest phase without clipping, so no lint rule
    /// fires for a reason the test did not intend.
    static let recommendedViewport = Size(width: 200, height: 60)

    let model: LateMotionModel

    var name: String { "late-motion" }

    @MainActor
    func body(state: ScenarioState) -> some View {
        state.registerTap(Self.probeID) { model.start() }
        return LateMotionView(model: model)
    }
}

private struct LateMotionView: View {
    @ObservedObject var model: LateMotionModel

    var body: some View {
        Color.orange
            .frame(width: 20 + Double(model.phase % 7) * 6, height: 12)
            .verdictProbe(LateMotionScenario.probeID, role: .image)
    }
}
