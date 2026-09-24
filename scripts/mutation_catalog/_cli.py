"""Mutation rows for the CLI, witness and demo scenarios.

Part of the `mutation_catalog` package; see its `__init__` for why the
catalog is split and for the rule about quoting text from these files.
"""

from mutation_catalog_types import Mutation, Runner  # noqa: F401

MUTATIONS: list[Mutation] = [
    Mutation(
        name="original scenario initializer invents an expectation",
        path="Sources/VerdictUIProbe/ScenarioRegistry.swift",
        old="self.init(viewport: viewport, expectations: [], make: make)",
        new='self.init(viewport: viewport, expectations: [Expectation("invented")], make: make)',
        test="ScenarioExpectationTests/testOriginalInitializerFunctionValuePreservesEmptyPolicy",
    ),
    Mutation(
        name="scenario expectation presence guard is inverted",
        path="Sources/VerdictUICLICore/VerdictEngine.swift",
        old="guard !entry.expectations.expectations.isEmpty else { return requested }",
        new="guard entry.expectations.expectations.isEmpty else { return requested }",
        test="ScenarioExpectationTests/testVerifyReportsMissingRequiredNodeInsteadOfFalsePass",
    ),
    Mutation(
        name="scenario entry discards compiled expectations",
        path="Sources/VerdictUIProbe/ScenarioRegistry.swift",
        old="self.expectations = ExpectationSet(name, expectations)",
        new="self.expectations = ExpectationSet(name, [])",
        test="ScenarioExpectationTests/testVerifyReportsMissingRequiredNodeInsteadOfFalsePass",
    ),
    Mutation(
        name="scenario verify bypasses compiled expectations",
        path="Sources/VerdictUICLICore/VerdictEngine.swift",
        old="var verdict = RuleEngine.run(\n            rules: judgmentRules(for: entry, requested: rules)",
        new="var verdict = RuleEngine.run(\n            rules: { _ = entry; return rules }()",
        test="ScenarioExpectationTests/testVerifyReportsMissingRequiredNodeInsteadOfFalsePass",
    ),
    Mutation(
        name="scenario action bypasses after-state expectations",
        path="Sources/VerdictUICLICore/VerdictEngine.swift",
        old="host: entry.host(viewport: viewport, deadline: deadline),\n            rules: judgmentRules(for: entry, requested: rules)",
        new="host: entry.host(viewport: viewport, deadline: deadline),\n            rules: rules",
        test="ScenarioExpectationTests/testActionExpectationsJudgeObservedAfterTreeAndPreserveDelta",
    ),
    Mutation(
        name="scenario sweep bypasses per-cell expectations",
        path="Sources/VerdictUICLICore/VerdictEngine.swift",
        old="let verdict = RuleEngine.run(\n                    rules: judgmentRules(for: entry, requested: rules)",
        new="let verdict = RuleEngine.run(\n                    rules: rules",
        test="ScenarioExpectationTests/testSweepUsesEachObservedViewportForExpectations",
    ),
    Mutation(
        name="scenario expectations replace requested lint rules",
        path="Sources/VerdictUICLICore/VerdictEngine.swift",
        old="return requested + [ScenarioExpectationRule(set: entry.expectations)]",
        new="return [ScenarioExpectationRule(set: entry.expectations)]",
        test="ScenarioExpectationTests/testConsumerExpectationsSupplementRequestedRules",
    ),
    Mutation(
        name="scenario expectation adapter discards observed viewport",
        path="Sources/VerdictUICLICore/VerdictEngine.swift",
        old="set.evaluate(in: root, context: context)",
        new="set.evaluate(in: root, context: .macOS(viewport: Rect(x: 0, y: 0, width: 4096, height: 4096), scenario: context.scenario))",
        test="ScenarioExpectationTests/testSweepUsesEachObservedViewportForExpectations",
    ),
    Mutation(
        name="nested consumer package path is ignored by Swift",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old='"--package-path", build.packageRoot.path',
        new='"--package-path", projectRoot.path',
        test="ProjectRunnerTests/testNestedBuildPackageUsesResolvedPathAndKeepsRunnerRootRelative",
    ),
    Mutation(
        name="nested consumer package defaults to a subdirectory",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old='resolvedBuildPackagePath(manifest.buildPackagePath ?? ".", projectRoot: projectRoot)',
        new='resolvedBuildPackagePath(manifest.buildPackagePath ?? "app", projectRoot: projectRoot)',
        test="ProjectScenariosTests/testBuildPackageDefaultAndContainedDirectoriesDecode",
    ),
    Mutation(
        name="nested consumer package bypasses strict JSON decoding",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old="buildPackagePath = values.contains(.buildPackagePath)",
        new="buildPackagePath = false",
        test="ProjectRunnerTests/testInvalidBuildPackagePathsRejectBeforeProcessLaunch",
    ),
    Mutation(
        name="nested consumer package without build product is accepted",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old="guard manifest.buildPackagePath == nil || manifest.buildProduct != nil else {",
        new="guard true else {",
        test="ProjectRunnerTests/testInvalidBuildPackagePathsRejectBeforeProcessLaunch",
    ),
    Mutation(
        name="nested consumer package path syntax is unchecked",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old='guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,\n            !path.contains("\\0"), !(path as NSString).isAbsolutePath else {',
        new="guard true else {",
        test="ProjectRunnerTests/testInvalidBuildPackagePathsRejectBeforeProcessLaunch",
    ),
    Mutation(
        name="nested consumer package follows an escaping symlink",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old="root.appendingPathComponent(path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL",
        new="root.appendingPathComponent(path, isDirectory: true).standardizedFileURL",
        test="ProjectRunnerTests/testInvalidBuildPackagePathsRejectBeforeProcessLaunch",
    ),
    Mutation(
        name="nested consumer package escapes consumer root",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old="guard package.pathComponents.starts(with: root.pathComponents) else {",
        new="guard true else {",
        test="ProjectRunnerTests/testInvalidBuildPackagePathsRejectBeforeProcessLaunch",
    ),
    Mutation(
        name="nested consumer package accepts nonexistent or non-directory path",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old="guard FileManager.default.fileExists(atPath: package.path, isDirectory: &isDirectory), isDirectory.boolValue else {",
        new="guard FileManager.default.fileExists(atPath: package.path, isDirectory: &isDirectory) || !isDirectory.boolValue else {",
        test="ProjectRunnerTests/testInvalidBuildPackagePathsRejectBeforeProcessLaunch",
    ),
    Mutation(
        name="AppKit diagnostic fixture releases before startup readiness",
        path="Tests/VerdictUICLICoreTests/AppKitCommandRunnerTests.swift",
        old="while !FileManager.default.fileExists(atPath: ready.path) {",
        new="while FileManager.default.fileExists(atPath: ready.path) {",
        test="AppKitCommandRunnerTests/testSlowStartupCannotTriggerDiagnosticReleaseBeforeExecution",
    ),
    Mutation(
        name="MCP initialize reports schema instead of software release",
        path="Sources/VerdictUICLICore/MCPTransport.swift",
        old="version: ReleaseVersion.current",
        new="version: SchemaVersion.current",
        test="MCPTransportTests/testInitializeReportsTheProtocolAndServerIdentity",
    ),
    Mutation(
        name="bounded command observes stale zero output size",
        path="Sources/VerdictUICLICore/BoundedCommand.swift",
        old="return Int(info.st_size)",
        new="return 0",
        test="AppKitCommandRunnerTests/testRunningDiagnosticOverflowFailsBeforeTheRunnerTimeout",
    ),
    Mutation(
        name="bounded command refuses valid output descriptors",
        path="Sources/VerdictUICLICore/BoundedCommand.swift",
        old="guard fstat(handle.fileDescriptor, &info) == 0, info.st_size >= 0 else {",
        new="guard fstat(handle.fileDescriptor, &info) != 0, info.st_size >= 0 else {",
        test="AppKitCommandRunnerTests/testCombinedDiagnosticAndTreeOutputIsBounded",
    ),
    Mutation(
        name="bounded command leaves running diagnostic overflow until timeout",
        path="Sources/VerdictUICLICore/BoundedCommand.swift",
        old="while try process.status() == nil {\n                    try validateSize()",
        new="while try process.status() == nil {",
        test="AppKitCommandRunnerTests/testRunningDiagnosticOverflowFailsBeforeTheRunnerTimeout",
    ),
    Mutation(
        name="AppKit runner loses diagnostic capture",
        path="Sources/VerdictUICLICore/AppKitCommand.swift",
        old="captureStandardError: true",
        new="captureStandardError: false",
        test="AppKitCommandRunnerTests/testNonzeroExitPreservesSeparateDiagnostics|AppKitCommandRunnerTests/testCombinedDiagnosticAndTreeOutputIsBounded",
    ),
    Mutation(
        name="AppKit runner ignores its timeout",
        path="Sources/VerdictUICLICore/AppKitCommand.swift",
        old="timeout: timeout, limit: limit, captureStandardError: true",
        new="timeout: 60, limit: limit, captureStandardError: true",
        test="AppKitCommandRunnerTests/testRunnerTimeoutIsUnavailableAndCannotReturnLateOutput",
    ),
    Mutation(
        name="AppKit runner ignores its output budget",
        path="Sources/VerdictUICLICore/AppKitCommand.swift",
        old="timeout: timeout, limit: limit, captureStandardError: true",
        new="timeout: timeout, limit: 8 * 1_024 * 1_024, captureStandardError: true",
        test="AppKitCommandRunnerTests/testCombinedDiagnosticAndTreeOutputIsBounded",
    ),
    Mutation(
        name="bounded command discards the diagnostic descriptor",
        path="Sources/VerdictUICLICore/BoundedCommand.swift",
        old="standardError: errorOutput?.fileDescriptor",
        new="standardError: nil",
        test="AppKitCommandRunnerTests/testNonzeroExitPreservesSeparateDiagnostics",
    ),
    Mutation(
        name="bounded command discards captured diagnostics",
        path="Sources/VerdictUICLICore/BoundedCommand.swift",
        old="let errorData = captureStandardError ? try Data(contentsOf: errorFile) : Data()",
        new="let errorData = Data()",
        test="AppKitCommandRunnerTests/testNonzeroExitPreservesSeparateDiagnostics",
    ),
    Mutation(
        name="bounded command refuses valid diagnostic storage",
        path="Sources/VerdictUICLICore/BoundedCommand.swift",
        old="guard FileManager.default.createFile(atPath: errorFile.path, contents: nil,",
        new="guard !FileManager.default.createFile(atPath: errorFile.path, contents: nil,",
        test="AppKitCommandRunnerTests/testLargeDiagnosticStreamCannotBlockTreeDelivery",
    ),
    Mutation(
        name="consumer command boundaries lose crash guardians",
        path="Sources/VerdictUICLICore/BoundedCommand.swift",
        old="typealias GuardedProcess = VerdictUIWeb.GuardedProcess",
        new="typealias GuardedProcess = VerdictUIWeb.OwnedCommandProcess",
        test="ProjectChecksTests/testCheckOwnerSIGKILLContainsActualDelegatedCommand|ProjectRunnerTests/testConfiguredBuildOwnerSIGKILLContainsBuildCommand|ProjectRunnerBrokerTests/testBusyMCPBrokerOwnerSIGKILLContainsHost|ProjectRunnerBrokerTests/testDaemonStartupOwnerSIGKILLContainsHost",
    ),
    Mutation(
        name="consumer broker discards failed cleanup ownership",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="if let child { try child.stop(grace: grace) }",
        new="if let child { _ = try? child.stop(grace: grace) }",
        test="ProjectRunnerBrokerTests/testLostChildOwnershipRetainsUnavailableHostAndRefusesReplacement",
    ),
    Mutation(
        name="consumer normal reload truncates persistent profile shutdown",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="let grace = orderly ? WebSession.consumerShutdownGrace : 2",
        new="let grace: TimeInterval = 2",
        test="ProjectRunnerBrokerTests/testNormalReloadAwaitsDelayedPersistentState",
    ),
    Mutation(
        name="consumer shutdown signal is mistaken for a protocol failure",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="stop(orderly: shouldStop())",
        new="stop(orderly: false)",
        test="ProjectRunnerBrokerTests/testShutdownDuringRequestRetainsNormalFlushAllowance",
    ),
    Mutation(
        name="consumer protocol failure receives normal shutdown allowance",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="let grace = orderly ? WebSession.consumerShutdownGrace : 2",
        new="let grace = WebSession.consumerShutdownGrace",
        test="ProjectRunnerBrokerTests/testProtocolFailureKeepsShortEscalation",
    ),
    Mutation(
        name="consumer daemon byte drips evade the absolute frame deadline",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="guard persistent || ProcessInfo.processInfo.systemUptime < frameDeadline else { return }",
        new="guard persistent || frameDeadline.isFinite else { return }",
        test="ProjectRunnerBrokerTests/testDrippedIncompleteSocketFrameHasAbsoluteDeadline",
    ),
    Mutation(
        name="consumer daemon empty lines renew an unfinished frame deadline",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="guard !line.isEmpty else { continue }",
        new="guard !line.isEmpty else { frameDeadline = ProcessInfo.processInfo.systemUptime + frameSeconds; continue }",
        test="ProjectRunnerBrokerTests/testEmptyLinesCannotExtendSocketFrameDeadline",
    ),
    Mutation(
        name="persistent consumer MCP is incorrectly subject to daemon idle budgets",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="guard persistent || ProcessInfo.processInfo.systemUptime < frameDeadline else { return }",
        new="guard ProcessInfo.processInfo.systemUptime < frameDeadline else { return }",
        test="ProjectRunnerBrokerTests/testPersistentMCPRemainsUsableAfterFrameBudgetIdle",
    ),
    Mutation(
        name="the launcher forgets the consumer build step",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old="try buildIfConfigured(projectRoot: root)",
        new="_ = root",
        test="ProjectRunnerTests/testLauncherBuildsBeforeItDelegates",
    ),
    Mutation(
        name="a consumer can declare the stock launcher as its runner",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old="guard ownsStockCatalog else {",
        new="guard ownsStockCatalog || true else {",
        test="ProjectRunnerTests/testAConsumerCannotDeclareTheStockLauncherAsItsRunner",
    ),
    Mutation(
        name="failed consumer builds can execute stale runners",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old="process.stop(grace: 0) == 0 else {",
        new="process.stop(grace: 0) != 0 else {",
        test="ProjectRunnerTests/testBuildFailureRefusesStaleRunner",
    ),
    Mutation(
        name="declared consumer build timeout is ignored",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old="let timeout = timeout ?? build.timeoutSeconds",
        new="let timeout = timeout ?? 300",
        test="ProjectRunnerTests/testDeclaredBuildTimeoutReachesRunningCommand",
    ),
    Mutation(
        name="explicit consumer build timeout override is ignored",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old="let timeout = timeout ?? build.timeoutSeconds",
        new="let timeout = build.timeoutSeconds",
        test="ProjectRunnerTests/testExplicitTimeoutOverridesProjectBuildBudget",
    ),
    Mutation(
        name="consumer build progress omits the effective budget",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old='"buildTimeoutSeconds": timeout,',
        new='"buildTimeoutSeconds": 0,',
        test="ProjectRunnerTests/testLauncherBuildsBeforeItDelegates",
    ),
    Mutation(
        name="consumer build progress reports declaration instead of override",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old='"buildTimeoutSeconds": timeout,',
        new='"buildTimeoutSeconds": build.timeoutSeconds,',
        test="ProjectRunnerTests/testExplicitTimeoutOverridesProjectBuildBudget",
    ),
    Mutation(
        name="consumer build default timeout changes silently",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old="timeoutSeconds: manifest.buildTimeoutSeconds ?? 300)",
        new="timeoutSeconds: manifest.buildTimeoutSeconds ?? 301)",
        test="ProjectScenariosTests/testBuildBudgetDefaultsAndDeclaredBoundsDecode",
    ),
    Mutation(
        name="explicit consumer build timeout values bypass decoding",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old="buildTimeoutSeconds = values.contains(.buildTimeoutSeconds)",
        new="buildTimeoutSeconds = false",
        test="ProjectRunnerTests/testInvalidBuildBudgetsRejectBeforeProcessLaunch",
    ),
    Mutation(
        name="consumer build timeout without build product is accepted",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old="guard manifest.buildProduct != nil else {",
        new="guard true else {",
        test="ProjectRunnerTests/testInvalidBuildBudgetsRejectBeforeProcessLaunch",
    ),
    Mutation(
        name="nonpositive consumer build timeout is accepted",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old="guard timeout > 0, timeout <= 1800 else {",
        new="guard true, timeout <= 1800 else {",
        test="ProjectRunnerTests/testInvalidBuildBudgetsRejectBeforeProcessLaunch",
    ),
    Mutation(
        name="oversized consumer build timeout is accepted",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old="guard timeout > 0, timeout <= 1800 else {",
        new="guard timeout > 0, true else {",
        test="ProjectRunnerTests/testInvalidBuildBudgetsRejectBeforeProcessLaunch",
    ),
    Mutation(
        name="consumer build timeout is ignored",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old="ProcessInfo.processInfo.systemUptime < deadline else {",
        new="ProcessInfo.processInfo.systemUptime > deadline else {",
        test="ProjectRunnerTests/testBuildTimeoutIsBounded",
    ),
    Mutation(
        name="empty build product is accepted",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old="guard !product.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,",
        new="guard true,",
        test="ProjectRunnerTests/testBuildConfigurationValidationAndDefault",
    ),
    Mutation(
        name="nul in build product is accepted",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old='!product.contains("\\0") else {',
        new="true else {",
        test="ProjectRunnerTests/testBuildConfigurationValidationAndDefault",
    ),
    Mutation(
        name="configuration without a build product is accepted",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old="guard manifest.buildProduct != nil,",
        new="guard true,",
        test="ProjectRunnerTests/testBuildConfigurationValidationAndDefault",
    ),
    Mutation(
        name="unknown build configuration is accepted",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old='["debug", "release"].contains(configuration) else {',
        new="!configuration.isEmpty else {",
        test="ProjectRunnerTests/testBuildConfigurationValidationAndDefault",
    ),
    Mutation(
        name="custom project daemon sockets collide",
        path="Sources/VerdictUICLICore/Commands.swift",
        old="String(digest, radix: 16)",
        new="String(digest & 0, radix: 16)",
        test="ProjectRunnerTests/testCustomDaemonPathsAreStableAndIsolated",
    ),
    Mutation(
        name="custom CLI registry injection is ignored",
        path="Sources/VerdictUICLICore/Commands.swift",
        old="if let environment = VerdictUIRunner.environment { return environment }",
        new="if let environment = VerdictUIRunner.environment, false { return environment }",
        test="ProjectRunnerTests/testCustomRegistryReachesAllStandardEnvironmentsAndDoesNotLeak",
    ),
    Mutation(
        name="runner delegation cycles are permitted",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old="guard !alreadyDelegated else {",
        new="guard !alreadyDelegated || true else {",
        test="ProjectRunnerTests/testDelegationCycleIsRefusedEvenWhenRunnerIsCurrentBinary",
    ),
    Mutation(
        name="a missing runner is accepted",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old="guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDirectory),",
        new="guard !FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDirectory),",
        test="ProjectRunnerTests/testExecutableAndRootAreResolvedFromNestedDirectory",
    ),
    Mutation(
        name="a runner directory is accepted",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old="!isDirectory.boolValue,",
        new="true,",
        test="ProjectRunnerTests/testDirectoryAndNonexecutableAreRefused",
    ),
    Mutation(
        name="a nonexecutable runner is accepted",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old="FileManager.default.isExecutableFile(atPath: executable.path)",
        new="true",
        test="ProjectRunnerTests/testDirectoryAndNonexecutableAreRefused",
    ),
    Mutation(
        name="self runner identity no longer prevents exec recursion",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old="if executable == current {",
        new="if executable != current {",
        test="ProjectRunnerTests/testCurrentBinaryDoesNotExecItself",
    ),
    Mutation(
        name="debug launcher delegates into release fixtures",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old="current.lastPathComponent == executable.lastPathComponent",
        new="current.lastPathComponent != executable.lastPathComponent",
        test="ProjectRunnerTests/testDebugAndReleaseOfSameLauncherDoNotDelegate",
    ),
    Mutation(
        name="live sweep is hijacked by scenario delegation",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old='if verb == "sweep",',
        new='if verb == "render",',
        test="ProjectRunnerTests/testOnlyScenarioCommandsDelegate",
    ),
    Mutation(
        name="help triggers project runner delegation",
        path="Sources/VerdictUICLICore/ProjectRunner.swift",
        old='guard !arguments.contains("--help"), !arguments.contains("-h"),',
        new='guard true, !arguments.contains("-h"),',
        test="ProjectRunnerTests/testOnlyScenarioCommandsDelegate",
    ),
    Mutation(
        name="blank runner declaration is accepted",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old="guard !manifest.runner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,",
        new="guard true,",
        test="ProjectRunnerTests/testInvalidManifestAndEmptyRunnerFailClosed",
    ),
    Mutation(
        name="runner path permits a nul byte",
        path="Sources/VerdictUICLICore/ProjectScenarios.swift",
        old='!manifest.runner.contains("\\0")',
        new="true",
        test="ProjectRunnerTests/testInvalidManifestAndEmptyRunnerFailClosed",
    ),
    Mutation(
        name="the demo swallows a scenario that cannot settle",
        path="Sources/VerdictUIDemoScenarios/DemoReport.swift",
        old="let tree = try await host.currentTree()",
        new="guard let tree = try? await host.currentTree() else { continue }",
        test="DemoReportTests/testAScenarioThatCannotSettleFailsTheRunAndNamesItself",
    ),
    Mutation(
        # `renderJSON` is what `main.swift` calls, so its failure branch gets its
        # own mutation rather than riding on `verdicts`'.
        name="renderJSON turns an unsettleable run into an empty document",
        path="Sources/VerdictUIDemoScenarios/DemoReport.swift",
        old="let data = try encoder.encode(try await verdicts(deadline: deadline))",
        new="let data = try encoder.encode((try? await verdicts(deadline: deadline)) ?? [])",
        test=(
            "DemoReportTests/testRenderJSONPropagatesTheFailureRatherThanEmittingAnEmptyDocument"
        ),
    ),
    Mutation(
        name="an entry ignores an explicit viewport override",
        path="Sources/VerdictUIDemoScenarios/DemoScenarios.swift",
        old="host(viewport ?? recommendedViewport, deadline)",
        new="host(recommendedViewport, deadline)",
        test=(
            "DemoScenarioCatalogTests/"
            "testAnEntryHostsAtAnExplicitViewportOrFallsBackToItsRecommendation"
        ),
    ),
    Mutation(
        # Actually DROPS the last catalog entry while its file stays on disk —
        # the exact drift the three hand-maintained counts cannot see, since
        # they only ever agree with each other. A comment-only edit here would
        # score MISSED while changing nothing, which is a worse signal than no
        # mutation at all.
        name="a scenario file stops being registered in the catalog",
        path="Sources/VerdictUIDemoScenarios/DemoScenarios.swift",
        old="""\
                make: { CleanSettingsScenario() }
            ),
        ]""",
        new="""\
                make: { CleanSettingsScenario() }
            ),
        ].dropLast()""",
        test="DemoScenarioCatalogTests/testEveryScenarioFileOnDiskIsRegisteredInTheCatalog",
    ),
    Mutation(
        # The published wire shape reverts to Swift's SYNTHESIZED enum encoding,
        # which wraps every payload in a positional `_0` key. That is exactly
        # what shipped for a whole wave while contracts/mcp-tools.md documented
        # the unwrapped form -- and no round-trip test could see it, because
        # both halves used the same Codable. Only a raw-JSON assertion fails.
        name="the daemon result reverts to synthesized enum encoding",
        path="Sources/VerdictUICLICore/Daemon.swift",
        # Keeps every binding live (no.md #31): the container is still made and
        # still encoded into, so the mutation compiles under -warnings-as-errors
        # and the witness genuinely RUNS.
        old="        case .scenarios(let value): try container.encode(value, forKey: .scenarios)",
        new=(
            "        case .scenarios(let value):\n"
            '            try container.encode(["_0": value], forKey: .scenarios)'
        ),
        test=("VerdictUICLICoreTests.DaemonTests/testTheResultShapeIsTheOneTheContractPublishes"),
        runner=Runner.SWIFT,
    ),
    Mutation(
        # An MCP NOTIFICATION (no id) gets answered. The protocol forbids it,
        # and a server that replies puts an unexpected message on the wire that
        # strict clients treat as a protocol error -- presenting to a user as
        # "the server never finished starting", with nothing in any log to say
        # which message was the unwanted one.
        name="the MCP transport answers notifications it is owed no reply for",
        path="Sources/VerdictUICLICore/MCPTransport.swift",
        old="        guard let id = message.id else { return nil }",
        new="        let id = message.id ?? .number(0)",
        test="VerdictUICLICoreTests.MCPTransportTests/testANotificationIsNotAnswered",
        runner=Runner.SWIFT,
    ),
    Mutation(
        # The envelope goes back to demanding tools/call's params shape. That is
        # the shipped defect: `params` is free-form per method, and `initialize`
        # -- the FIRST message of every real session -- fills it with
        # protocolVersion/capabilities/clientInfo and no `name`, so a strict
        # decode rejects the whole ENVELOPE and the message never reaches the
        # handler that would have answered it. The server then answers every
        # real client's opening message with a parse error while its own suite
        # reports the handshake working, because the suite's handshake test
        # sends `initialize` with no params key at all.
        #
        # `try?` -> `try` keeps every binding live and the file compiling, per
        # no.md #31: a mutation that fails to BUILD scores as if the guard were
        # tested, because a compiler's exit 1 is indistinguishable from a failing
        # assertion's at the harness boundary.
        name="the MCP envelope rejects any params that is not a tools/call params",
        path="Sources/VerdictUICLICore/MCPTransport.swift",
        old="        params = try? container.decodeIfPresent(MCPCallParams.self, forKey: .params)",
        new="        params = try container.decodeIfPresent(MCPCallParams.self, forKey: .params)",
        test="VerdictUICLICoreTests.MCPTransportTests/testTheHandshakeARealClientSendsIsAnswered",
        runner=Runner.SWIFT,
    ),
    Mutation(
        # The act delta stops omitting empty lists. Measured 2026-08-12: an act
        # that changes nothing then costs 170 B to say so, against 2 B -- and
        # that is the COMMONEST act in a real agent loop, so the compaction
        # would be winning on the rare payload and losing 4x on the frequent
        # one. `_ =` rather than deleting the line, so every binding stays live
        # and the mutation still COMPILES under -warnings-as-errors (no.md #31).
        name="the act delta spells its empty lists instead of omitting them",
        path="Sources/VerdictUICLICore/CompactDelta.swift",
        old="        if !changed.isEmpty { try container.encode(changed, forKey: .changed) }",
        new="        try container.encode(changed, forKey: .changed)",
        test="ActToolTests/testTheStepResponsePublishesTheDocumentedKeys",
    ),
    Mutation(
        # Added nodes stop being reachable from exactly one addition. A node
        # claimed twice, or by nothing, means the table does not describe the
        # subtrees `added` names -- the one malformed case that rebuilds a
        # PLAUSIBLE tree rather than crashing, so a client would hold a tree the
        # engine never rendered and nothing downstream could tell.
        name="a compact delta stops refusing a node table nothing references",
        path="Sources/VerdictUICLICore/CompactDelta.swift",
        old="        guard visited.allSatisfy({ $0 }) else { return nil }",
        new="        _ = visited.allSatisfy { $0 }",
        test="ActToolTests/testAMalformedCompactDeltaExpandsToNil",
    ),
    Mutation(
        # An act missing its payload stops being refused and gets a default
        # instead. `setText` without `text` would type an EMPTY STRING into the
        # field and then report a verdict about a screen the caller never asked
        # for -- a true-looking answer to a question nobody posed.
        name="an act missing its payload is defaulted rather than refused",
        path="Sources/VerdictUICLICore/Daemon.swift",
        old="""            guard let text else {
                throw TranslationError.missingArgument(kind: kind, argument: "text")
            }
            return .setText(probe, text)""",
        new='            return .setText(probe, text ?? "")',
        test="ActToolTests/testAVerbMissingItsPayloadIsRefusedRatherThanDefaulted",
    ),
    Mutation(
        # A tool is served under a name the published contract does not carry,
        # which is invisible to every client author reading the contract. Found
        # live on this guard's FIRST run -- judge_appkit had shipped served and
        # undocumented since 2026-08-17 with nothing able to see it.
        #
        # The mutation renames the SERVED tool rather than weakening the test:
        # a row that made the assertion self-referential (`served = documented`)
        # scored UNNOTICED and was right to -- no test can witness its own
        # vacuity, so a mutation must break the SUBJECT, not the witness.
        name="a served MCP tool goes undocumented in the published contract",
        path="Sources/VerdictUICLICore/MCPServer.swift",
        old='                name: "actions",',
        new='                name: "actions_undocumented",',
        test=("MCPServerTests/testEveryServedToolIsDocumentedAndEveryDocumentedToolIsServed"),
    ),
    Mutation(
        # The SD6 permission path stops reporting itself. A caller that ASKED
        # for cross-validation and could not get it then receives an ordinary
        # PASS -- "the two channels agree" and "only one channel ran" arriving
        # as the same answer, which is the exact silent-weakening Task 3 exists
        # to prevent. Hand-verified 2026-08-12 in both directions: exit 1 with
        # 6 tests executed and 8 failures under the mutation, byte-identical
        # restore (sha256 6c3aa8df...).
        name="a witness that could not run stops saying so",
        path="Sources/VerdictUIWitness/CrossValidation.swift",
        old="            return [Reconcile.unavailable(reason: reason(for: error))]",
        new="            return []",
        test="CrossValidationTests/testAFailedReadBecomesAWarningFindingNamingTheReason",
    ),
    Mutation(
        # `--cross-validate` becomes a no-op: the engine ignores the flag and
        # returns an inner-loop-only verdict. The caller then asked for two
        # channels, was given one, and is told nothing -- the whole point of
        # Wave 8 lost silently, since an inner-loop PASS looks exactly like a
        # cross-validated one once the timing and the finding are gone.
        # `= false` rather than deleting the branch, so every binding stays live
        # and the mutation still COMPILES under -warnings-as-errors (no.md #31).
        name="the cross-validate flag stops being honoured",
        path="Sources/VerdictUICLICore/VerdictEngine.swift",
        old="        if crossValidate {",
        new="        if false, crossValidate {",
        test="CrossValidateFlagTests/testRequestingCrossValidationAlwaysReportsWhatHappened",
    ),
    Mutation(
        # The AX walk loses its BREADTH bound and keeps only its depth bound.
        # Depth stops a cycle; it says nothing about a tree 64 deep with modest
        # branching, where each node costs ~5 CROSS-PROCESS accessibility calls
        # -- IPC-bound work that no amount of waiting finishes. Measured
        # 2026-08-12: reading Finder like this did not terminate in 60 s and was
        # SIGKILLed, while the same read with the budget takes ~2 s. A budget of
        # Int.max keeps every binding live and still COMPILES (no.md #31).
        # HAND-VERIFIED ONLY, and deliberately not scored by the sweep. The
        # mutation makes the guarded read HANG rather than fail, so the witness
        # exits on a timeout -- and a timeout is indistinguishable, at the
        # harness's exit-code boundary, from a hostile environment or a stuck
        # machine (no.md #25's rule: ask whether the WITNESS RAN, not whether
        # the row scored). Measured 2026-08-12: mutated, exit 124 with no
        # summary line at a 120 s bound; restored, 2 tests / 0 failures in
        # ~3.3 s; byte-identical restore (ac7da344). The row is kept because
        # --verify-targets still pins the anchor, so a refactor that moves or
        # renames the budget is caught even though the mutation is not scored.
        name="the AX walk keeps its depth bound but loses its node budget",
        path="Sources/VerdictUIWitness/AXReader.swift",
        old="    static let maximumNodes = 4096",
        new="    static let maximumNodes = Int.max",
        test="ThirdPartyAuditTests/testTheReaderIsBoundedAgainstAHostileTree",
        # Measured 2026-08-15: this row was the ONLY UNNOTICED in a 121-row
        # sweep, and it was not a coverage gap — the witness had SKIPPED. Its
        # first three statements are XCTSkipIf(isHeadless),
        # XCTSkipUnless(AXReader.isTrusted), and a skip when no third-party app
        # is running, and XCTest reports every one of those as
        # `passed (0.062 seconds)` with `Executed 1 test, with 0 failures` and
        # exit 0 — no skip marker at any verbosity. So the harness read a
        # perfectly good guard as untested and accused working code.
        skips_when=(
            "the host is headless, lacks Accessibility trust, or is running no "
            "third-party app with a readable window"
        ),
    ),
    Mutation(
        # `focus` stops resolving probe ids and honours structural paths only.
        # A verdict cites whichever identity a node HAS, so half the nodes an
        # agent can see would become unreachable by the one verb that exists to
        # reach them -- and the failure is silent per-node: the tool still works
        # for every path-addressed node, so a spot check passes.
        name="focus resolves structural paths but stops resolving probe ids",
        path="Sources/VerdictUICLICore/Daemon.swift",
        old="        return all.first { $0.structuralPath == path } ?? all.first { $0.id == path }",
        new="        return all.first { $0.structuralPath == path }",
        test="FocusToolTests/testFocusResolvesAStructuralPathAsWellAsAProbeID",
    ),
    Mutation(
        # The witness window starts COMPOSITING again, which is the defect the
        # owner reported: a titled window flashing at the bottom-left of the
        # screen once per scenario. Readability and visibility are independent
        # properties of one window, and 22 witness tests passed for a whole wave
        # while asserting only the first -- so this row guards the assertion that
        # closed that gap, not the window's existence (which every other witness
        # test already covers). Assigning 1 rather than deleting the line keeps
        # the statement live and compiles (no.md #31).
        name="the witness window composites again, flashing on the owner's screen",
        path="Sources/VerdictUIWitness/WitnessHost.swift",
        old="        window.alphaValue = 0",
        new="        window.alphaValue = 1",
        test="WitnessIntegrationTests/testTheWitnessWindowIsReadableWithoutBeingVisible",
    ),
    Mutation(
        # The SECOND half of "readable without being visible", and the half that
        # kept flashing after alphaValue=0 shipped. The window was genuinely
        # transparent (measured on-screen at alpha=0.0) while the owner still saw
        # a flash on every run: what he saw was the APPLICATION arriving, not its
        # window drawing, and `open -n` starts one per scenario (~23 per suite).
        # The comment claiming .accessory is "not a first-class AX citizen" was
        # FALSE -- measured with two bundles differing only in the policy, both
        # read AXerr=0 windows=1 from an external process, and only the foreground
        # count differed (0 vs 1). Substituting the enum case keeps every binding
        # live and compiles (no.md #31).
        name="the witness host becomes a foreground app again, animating on launch",
        path="Sources/VerdictUIWitness/WitnessHost.swift",
        old="app.setActivationPolicy(.accessory)",
        new="app.setActivationPolicy(.regular)",
        test="WitnessIntegrationTests/testTheWitnessDoesNotRunAsAForegroundApp",
    ),
    Mutation(
        # Reverts the per-process bundle to the pre-fix per-launch path. This
        # is the ACTUAL regression rather than a synthetic break: never reusing
        # the cached bundle means every launch writes a new path and asks
        # LaunchServices to register it, which is the leak. Every binding stays
        # live and it compiles (no.md #31).
        name="the host bundle is written per launch again, leaking a registration each time",
        path="Sources/VerdictUIWitness/WitnessHostProcess.swift",
        old="if let cached = cachedBundles[key], "
        "FileManager.default.fileExists(atPath: cached.path) {",
        new="if false, let cached = cachedBundles[key] {",
        test=(
            "VerdictUIWitnessTests.WitnessIntegrationTests"
            "/testRepeatedLaunchesReuseOneTemporaryDirectory"
        ),
    ),
    Mutation(
        # CIS-009B4F22: `-l <id>` is what makes a capture window-only. Without it
        # screencapture grabs the whole screen, which can include an unrelated
        # remote session carrying patient data.
        name="window capture loses -l and becomes a full-screen grab",
        path="Sources/VerdictUIWitness/WindowCapture.swift",
        old='["-x", "-o", "-l", String(windowID), path]',
        new='["-x", "-o", String(windowID), path]',
        test="AXSurfaceAndActionTests/testTheCaptureArgvIsAlwaysWindowOnly",
    ),
    Mutation(
        # CIS-1DDD35B2: a running pid has fixed locale and appearance, so a
        # sweep over it would report one configuration as a whole matrix.
        name="a sweep accepts a running pid instead of refusing it",
        path="Sources/VerdictUICLICore/LiveCommands.swift",
        old="if target.pid != nil { throw Problem.runningAppCannotBeSwept }",
        new="if target.pid == -12_345 { throw Problem.runningAppCannotBeSwept }",
        test="LiveCommandTests/testASweepRefusesARunningPidInertDynamicTypeAndAnEmptyMatrix",
    ),
    Mutation(
        # CIS-DD4A93B7: `menubar` and `extras` are different surfaces; swapping
        # them reads the status-item bar where the main menu was asked for.
        name="the menubar and extras surfaces read each other's bar",
        path="Sources/VerdictUIWitness/AXReader.swift",
        old="let key = surface == .menuBar ? kAXMenuBarAttribute : kAXExtrasMenuBarAttribute",
        new="let key = surface == .menuBar ? kAXExtrasMenuBarAttribute : kAXMenuBarAttribute",
        test="AXSurfaceAndActionTests/testAllSurfacesIncludeTheMenuBarNotJustTheFrontWindow",
        # The witness reads Finder cross-process; XCTest reports its skip as a
        # pass, so the condition is declared here (no.md #62).
        skips_when=("the host is headless, lacks Accessibility trust, or Finder is not running"),
    ),
]
