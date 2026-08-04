// VerdictUIDemo — renders every demo scenario and prints one verdict apiece.
//
// One statement, on purpose. Everything this program does lives in
// `DemoReport.renderJSON()` inside VerdictUIDemoScenarios, because a SwiftPM
// test target cannot import an executable target: logic placed here could only
// be verified by spawning a subprocess and parsing its stdout, while logic in
// the library is called directly by `DemoReportTests`. Top-level code in
// `main.swift` is `@MainActor` and may `await`, which is exactly what the
// main-actor-isolated harness needs.
import VerdictUIDemoScenarios

print(try await DemoReport.renderJSON())
