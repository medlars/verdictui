// VerdictUIDemo — renders every demo scenario and prints one verdict apiece.
//
// One do/catch, on purpose. Everything this program does lives in
// `DemoReport.renderJSON()` inside VerdictUIDemoScenarios, because a SwiftPM
// test target cannot import an executable target: logic placed here could only
// be verified by spawning a subprocess and parsing its stdout, while logic in
// the library is called directly by `DemoReportTests`. Top-level code in
// `main.swift` is `@MainActor` and may `await`, which is exactly what the
// main-actor-isolated harness needs.
//
// The catch is the process's failure contract: without it a thrown
// `OracleHostError` would terminate through the runtime's unhandled-error
// trap — SIGABRT, exit code 134, nothing on stderr a human can read — and a
// CI step checking for a nonzero-but-meaningful status would see a crash
// indistinguishable from a harness bug. Here a failed run is exit code 1 with
// the error (which names the scenario) on stderr, and stdout is either one
// complete JSON document or empty — never a partial document.
import Foundation
import VerdictUIDemoScenarios

do {
    print(try await DemoReport.renderJSON())
} catch {
    FileHandle.standardError.write(Data("verdictui-demo: \(error)\n".utf8))
    exit(1)
}
