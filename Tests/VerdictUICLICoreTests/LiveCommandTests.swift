import XCTest

@testable import VerdictUICLICore
@testable import VerdictUIDemoScenarios
@testable import VerdictUIKernel
@testable import VerdictUIWitness

/// The live-app verbs: target validation, the sweep matrix, and the refusals
/// that must happen BEFORE anything is launched (CIS-B5DA3C41, CIS-1DDD35B2,
/// CIS-15F8D85E, CIS-07CB1181).
@MainActor
final class LiveCommandTests: XCTestCase {

    private func environment() -> (CommandEnvironment, CapturedOutput) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("verdictui-live-\(UUID().uuidString)")
        let output = CapturedOutput()
        return (
            CommandEnvironment(
                engine: VerdictEngine(
                    registry: DemoScenarios.registry, baselines: BaselineStore.standard(root: root)),
                output: output,
                pixelArtifactRoot: root.appendingPathComponent(PixelArtifact.directory)),
            output
        )
    }

    // MARK: - target

    func testEnvironmentPairsParseAndKeepEqualsInTheValue() throws {
        XCTAssertEqual(
            try LiveTarget.parseEnvironment(["A=1", "URL=x=y"]), ["A": "1", "URL": "x=y"])
        XCTAssertThrowsError(try LiveTarget.parseEnvironment(["novalue"]))
        XCTAssertThrowsError(try LiveTarget.parseEnvironment(["=1"]))
    }

    func testATargetMustBeExactlyOnePidOrApp() {
        XCTAssertThrowsError(try LiveTarget().validate()) {
            XCTAssertEqual($0 as? LiveTarget.Problem, .noTarget)
        }
        XCTAssertThrowsError(try LiveTarget(pid: 1, app: "/X.app").validate()) {
            XCTAssertEqual($0 as? LiveTarget.Problem, .bothTargets)
        }
        XCTAssertNoThrow(try LiveTarget(pid: 1).validate())
        XCTAssertNoThrow(try LiveTarget(app: "/X.app", launchArguments: ["-Flag"]).validate())
    }

    /// Launch arguments cannot reach a process that is already running; a pid
    /// with them is refused rather than silently ignoring them.
    func testLaunchOptionsOnARunningPidAreRefused() {
        XCTAssertThrowsError(try LiveTarget(pid: 1, launchArguments: ["-Fixture"]).validate()) {
            XCTAssertEqual($0 as? LiveTarget.Problem, .launchOptionsWithoutApp)
        }
    }

    func testSurfaceResolutionIncludingAll() throws {
        XCTAssertEqual(try LiveTarget(pid: 1, surface: "menubar").resolvedSurface(), .menuBar)
        XCTAssertNil(try LiveTarget(pid: 1, surface: "all").resolvedSurface())
        XCTAssertThrowsError(try LiveTarget(pid: 1, surface: "sidebar").validate())
    }

    // MARK: - sweep matrix

    func testTheSweepMatrixIsTheProductOfItsAxes() throws {
        let cells = try LiveSweepCommand(
            target: LiveTarget(app: "/X.app"), locales: ["en_US", "de_DE"],
            colorSchemes: ["light", "dark"]
        ).cells()
        XCTAssertEqual(cells.count, 4)
        XCTAssertEqual(cells.first, .init(locale: "en_US", colorScheme: "light"))
        XCTAssertEqual(cells.last, .init(locale: "de_DE", colorScheme: "dark"))
        let one = try LiveSweepCommand(
            target: LiveTarget(app: "/X.app"), locales: [], colorSchemes: ["dark"]
        ).cells()
        XCTAssertEqual(one, [.init(locale: nil, colorScheme: "dark")])
    }

    func testASweepRefusesARunningPidInertDynamicTypeAndAnEmptyMatrix() {
        XCTAssertThrowsError(
            try LiveSweepCommand(target: LiveTarget(pid: 1), locales: ["de_DE"], colorSchemes: [])
                .cells()
        ) { XCTAssertEqual($0 as? LiveSweepCommand.Problem, .runningAppCannotBeSwept) }
        XCTAssertThrowsError(
            try LiveSweepCommand(
                target: LiveTarget(app: "/X.app"), locales: [], colorSchemes: [],
                dynamicTypeSizes: ["accessibility3"]
            ).cells()
        ) { XCTAssertEqual($0 as? LiveSweepCommand.Problem, .dynamicTypeIsInertOnMacOS) }
        XCTAssertThrowsError(
            try LiveSweepCommand(target: LiveTarget(app: "/X.app"), locales: [], colorSchemes: [])
                .cells()
        ) { XCTAssertEqual($0 as? LiveSweepCommand.Problem, .noAxis) }
        XCTAssertThrowsError(
            try LiveSweepCommand(target: LiveTarget(app: "/X.app"), locales: [], colorSchemes: ["sepia"])
                .cells()
        ) { XCTAssertEqual($0 as? LiveSweepCommand.Problem, .badColorScheme("sepia")) }
    }

    func testVariantArgumentsSelectLocaleAndAppearance() {
        XCTAssertEqual(
            AppLauncher.variantArguments(locale: "de_DE", colorScheme: "dark"),
            ["-AppleLanguages", "(de-DE)", "-AppleLocale", "de_DE", "-AppleInterfaceStyle", "Dark"])
        XCTAssertEqual(
            AppLauncher.variantArguments(locale: nil, colorScheme: "light"),
            ["-AppleInterfaceStyle", "Light"])
        XCTAssertEqual(AppLauncher.variantArguments(locale: nil, colorScheme: nil), [])
    }

    // MARK: - colour on a rendered scenario (no permissions needed)

    /// The in-process render is windowless and needs no Screen Recording, so
    /// this is the colour path that works on every host: real pixels, real
    /// tree, sampled per node.
    func testRenderWithColorsAnnotatesTheTreeFromItsOwnPixels() async throws {
        let (environment, output) = self.environment()
        XCTAssertTrue(RenderCommand(scenario: "demo-clean-settings", colors: true).pixels)
        let code = await RenderCommand(scenario: "demo-clean-settings", colors: true)
            .run(environment, pretty: false)
        XCTAssertEqual(code, .pass, output.standardError)
        let report = try JSONDecoder().decode(
            PixelRenderReport.self, from: Data(output.standardOutput.utf8))
        let nodes = report.tree.flattened()
        XCTAssertNotNil(report.tree.attributes[ColorSampler.backgroundKey])
        let texts = nodes.filter { $0.text?.isEmpty == false }
        XCTAssertFalse(texts.isEmpty)
        XCTAssertTrue(
            texts.contains { $0.attributes[ColorSampler.contrastKey]?.numberValue != nil },
            "at least one rendered text node has a sampled contrast")
    }

    /// Control: without --colors the same render carries no colour keys, so the
    /// annotation above is the flag's doing and not something always present.
    func testRenderWithoutColorsCarriesNoColourKeys() async throws {
        let (environment, output) = self.environment()
        _ = await RenderCommand(scenario: "demo-clean-settings", pixels: true)
            .run(environment, pretty: false)
        let report = try JSONDecoder().decode(
            PixelRenderReport.self, from: Data(output.standardOutput.utf8))
        XCTAssertFalse(
            report.tree.flattened().contains { $0.attributes[ColorSampler.backgroundKey] != nil })
    }

    // MARK: - the vacuity guard and externally observed trees

    private func probelessTree() -> SemanticNode {
        SemanticNode(
            id: "", role: .container, frame: Rect(x: 0, y: 0, width: 200, height: 100),
            structuralPath: "root",
            children: [
                SemanticNode(
                    id: "", role: .button, frame: Rect(x: 0, y: 0, width: 4, height: 4),
                    text: "Go", structuralPath: "root/button[0]")
            ]
        ).withAssignedStructuralPaths()
    }

    /// An accessibility tree carries no probe ids, so judging one under the
    /// probe-channel rules reported `vacuous-verdict` on a tree it had read
    /// perfectly — measured 2026-09-10 against a live Calculator, 58 nodes.
    func testAnExternallyObservedTreeIsNotCalledVacuous() {
        let verdict = JudgeCommand.judge(
            tree: probelessTree(), viewportWidth: 200, viewportHeight: 100,
            scenarioName: "live", requiresProbedNodes: false)
        XCTAssertFalse(verdict.findings.contains { $0.rule == RuleEngine.vacuousVerdictRule })
        XCTAssertTrue(
            verdict.findings.contains { $0.rule == "tap-target" },
            "the other rules still judge the tree — this is not a blanket exemption")
    }

    /// The control, and the reason the flag is not a default: a PROBE-channel
    /// tree with nothing probed must still be called vacuous, because zero
    /// findings otherwise derives to PASS on a screen nobody observed.
    func testAProbeChannelTreeWithNoProbesIsStillVacuous() {
        let verdict = JudgeCommand.judge(
            tree: probelessTree(), viewportWidth: 200, viewportHeight: 100,
            scenarioName: "probe")
        XCTAssertTrue(verdict.findings.contains { $0.rule == RuleEngine.vacuousVerdictRule })
    }

    // MARK: - refusals before any launch

    func testAnActWithoutAPathIsAToolErrorNotALaunch() async {
        let (environment, output) = self.environment()
        let code = await InspectCommand(
            target: LiveTarget(app: "/nonexistent/Never.app"), act: "focus"
        ).run(environment, pretty: false)
        XCTAssertEqual(code, .couldNotVerify)
        XCTAssertTrue(output.standardError.contains("--path"), output.standardError)
    }

    func testAnUnknownVerbIsRefusedAndTheVocabularyIsListed() async {
        let (environment, output) = self.environment()
        let code = await InspectCommand(
            target: LiveTarget(app: "/nonexistent/Never.app"), path: "root", act: "drag"
        ).run(environment, pretty: false)
        XCTAssertEqual(code, .couldNotVerify)
        XCTAssertTrue(output.standardError.contains("set-value"), output.standardError)
    }

    func testLaunchingSomethingThatIsNotAnAppIsAToolError() async {
        let (environment, output) = self.environment()
        let code = await LiveJudgeCommand(target: LiveTarget(app: "/nonexistent/Never.app"))
            .run(environment, pretty: false, summary: false)
        XCTAssertEqual(code, .couldNotVerify)
        XCTAssertTrue(output.standardError.contains("not an application bundle"), output.standardError)
        XCTAssertTrue(output.standardOutput.isEmpty, "a tool error writes no verdict")
    }

    func testJudgingAllSurfacesAtOnceIsRefused() async {
        let (environment, output) = self.environment()
        let code = await LiveJudgeCommand(target: LiveTarget(pid: 1, surface: "all"))
            .run(environment, pretty: false, summary: false)
        XCTAssertEqual(code, .couldNotVerify)
        XCTAssertTrue(output.standardError.contains("one surface"), output.standardError)
    }

    /// A live judge of a pid with nothing to read is exit 2, never a verdict:
    /// "I could not read your app" must not look like "your app failed".
    func testJudgingAnUnreadablePidIsExitTwoNotAVerdict() async {
        let (environment, output) = self.environment()
        let code = await LiveJudgeCommand(target: LiveTarget(pid: 1))
            .run(environment, pretty: false, summary: false)
        XCTAssertEqual(code, .couldNotVerify)
        XCTAssertTrue(output.standardOutput.isEmpty)
    }
}
