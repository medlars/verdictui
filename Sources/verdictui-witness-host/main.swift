import AppKit
import SwiftUI
import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import VerdictUIWitness

// The windowed half of the cross-validation channel.
//
// Deliberately a SEPARATE PROCESS, and not for tidiness: a process cannot read
// its own accessibility tree. Measured 2026-08-12 — `kAXWindowsAttribute`
// against the caller's own pid returns -25208 while `NSApp.windows` reports one
// visible window in the same instant. So the reader and the rendered window
// must live in different processes, and this is the one that renders.
//
// Contract with the reader (`WitnessHostProcess`): print `WITNESS-READY <pid>`
// on stdout once the window is up, then hand control to AppKit. The reader
// waits for that line rather than sleeping — a fixed sleep is a race that
// passes on a fast machine and fails on a loaded one.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: verdictui-witness-host <scenario-name> [lifetime-seconds]\n".utf8))
    exit(2)
}
let scenarioName = arguments[1]
let lifetime = arguments.count >= 3 ? (Double(arguments[2]) ?? 30) : 30

// Resolves across BOTH catalogs — the demo scenarios and Wave 8's lie fixtures.
// The lie fixtures are the reconciler's honesty proof, so the external channel
// must be able to render them; they stay out of `DemoScenarios.all` (the array
// the sweep, the CLI and `list_scenarios` iterate) precisely so a scenario that
// misreports on purpose is never shown to a user as a product defect.
guard let entry = LieScenarios.anyEntry(named: scenarioName) else {
    FileHandle.standardError.write(
        Data("unknown scenario '\(scenarioName)'\n".utf8))
    exit(3)
}

MainActor.assumeIsolated {
    // Render the scenario's PROBED body, so both channels describe the same
    // views. A witness that rendered an unprobed variant would be comparing two
    // different view trees and calling the difference a defect.
    // The scenario's own recommended viewport, not a size chosen here: several
    // demo scenarios define their planted defect RELATIVE to it
    // (OffscreenButtonScenario's button is offscreen only at that width), so
    // rendering at any other size verifies a different scenario than the probe
    // channel does.
    let viewport = entry.recommendedViewport
    let host = WitnessHost(
        content: entry.witnessBody(),
        size: CGSize(width: viewport.width, height: viewport.height)
    )
    print("WITNESS-READY \(ProcessInfo.processInfo.processIdentifier)")
    fflush(stdout)
    host.run(lifetime: lifetime)
}
