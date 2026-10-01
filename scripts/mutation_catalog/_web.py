"""Web-engine guards and their real browser / pure CDP witnesses."""

from mutation_catalog_types import Mutation, Runner

_BASE = "Sources/VerdictUIWeb/"
_TEST = "VerdictUIWebTests."

MUTATIONS: list[Mutation] = [
    Mutation(
        name="web lifecycle evidence JSON encoding validity",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old="guard JSONSerialization.isValidJSONObject(value),",
        new="guard !JSONSerialization.isValidJSONObject(value),",
        test=_TEST
        + "LifecycleDiagnosticExportTests/testMarkerAndOutputLimitsNeverReturnRawContent",
    ),
    Mutation(
        name="web lifecycle evidence receipt byte bound",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old='guard data.count <= inputLimit else { return ["state": "truncated"] }\n            guard let value',
        new='guard data.count <= inputLimit + 1 else { return ["state": "truncated"] }\n            guard let value',
        test=_TEST
        + "LifecycleDiagnosticExportTests/testMissingPartialMalformedAndOversizedReceiptsAreUnavailable",
    ),
    Mutation(
        name="web lifecycle evidence exact receipt fields",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old="Set(value.keys) == fields",
        new="true",
        test=_TEST
        + "LifecycleDiagnosticExportTests/testMissingPartialMalformedAndOversizedReceiptsAreUnavailable",
    ),
    Mutation(
        name="web lifecycle evidence numeric type boundary",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old="CFGetTypeID(number) != CFBooleanGetTypeID()",
        new="true",
        test=_TEST
        + "LifecycleDiagnosticExportTests/testMissingPartialMalformedAndOversizedReceiptsAreUnavailable",
    ),
    Mutation(
        name="web lifecycle evidence boolean type boundary",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old="CFGetTypeID(number) == CFBooleanGetTypeID()",
        new="true",
        test=_TEST
        + "LifecycleDiagnosticExportTests/testEnumsBooleansAndRegularFileBoundaryRejectUntrustedValues",
    ),
    Mutation(
        name="web lifecycle evidence signal enum allowlist",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old='["default", "ignore", "callable"].contains(text)',
        new="true",
        test=_TEST
        + "LifecycleDiagnosticExportTests/testEnumsBooleansAndRegularFileBoundaryRejectUntrustedValues",
    ),
    Mutation(
        name="web lifecycle evidence receipt regular-file boundary",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old='    static func read(_ name: String, root: URL, fields: Set<String>) -> [String: Any] {\n        let url = root.appendingPathComponent(name)\n        guard FileManager.default.fileExists(atPath: url.path) else { return ["state": "missing"] }\n        do {\n            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)\n            guard attributes[.type] as? FileAttributeType == .typeRegular else { return ["state": "invalid_file"] }\n',
        new='    static func read(_ name: String, root: URL, fields: Set<String>) -> [String: Any] {\n        let url = root.appendingPathComponent(name)\n        guard FileManager.default.fileExists(atPath: url.path) else { return ["state": "missing"] }\n        do {\n            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)\n            _ = attributes\n',
        test=_TEST
        + "LifecycleDiagnosticExportTests/testEnumsBooleansAndRegularFileBoundaryRejectUntrustedValues",
    ),
    Mutation(
        name="web lifecycle evidence exact normal marker",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old='data == Data("normal".utf8) ? "observed" : "malformed"',
        new='!data.isEmpty ? "observed" : "malformed"',
        test=_TEST
        + "LifecycleDiagnosticExportTests/testMarkerAndOutputLimitsNeverReturnRawContent",
    ),
    Mutation(
        name="web lifecycle evidence marker byte bound",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old="guard data.count <= 6 else",
        new="guard data.count <= 7 else",
        test=_TEST
        + "LifecycleDiagnosticExportTests/testMarkerAndOutputLimitsNeverReturnRawContent",
    ),
    Mutation(
        name="web lifecycle evidence output byte bound",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old="guard data.count <= outputLimit else",
        new="guard data.count <= outputLimit * 2 else",
        test=_TEST
        + "LifecycleDiagnosticExportTests/testMarkerAndOutputLimitsNeverReturnRawContent",
    ),
    Mutation(
        name="web lifecycle evidence stderr byte bound",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old='guard data.count <= inputLimit else { return ["state": "truncated"] }\n            guard let text',
        new='guard data.count <= inputLimit + 1 else { return ["state": "truncated"] }\n            guard let text',
        test=_TEST
        + "LifecycleDiagnosticExportTests/testKnownShutdownFailureIsReportedWithoutStderrContent",
    ),
    Mutation(
        name="web lifecycle evidence known shutdown failure signal",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old='.contains("verdictui: browser shutdown incomplete")',
        new='.contains("deliberately absent shutdown marker")',
        test=_TEST
        + "LifecycleDiagnosticExportTests/testKnownShutdownFailureIsReportedWithoutStderrContent",
    ),
    Mutation(
        name="web lifecycle evidence retained live identities",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old='["running", "leader_alive", "child_alive", "wrapper_alive"].contains',
        new='["running"].contains',
        test=_TEST + "LifecycleDiagnosticExportTests/testLiveAndIncompleteCaptureCannotBeObserved",
    ),
    Mutation(
        name="web lifecycle evidence incomplete availability",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old='let incomplete = evidence.values.contains { ($0["state"] as? String) != "observed" }',
        new="let incomplete = evidence.isEmpty",
        test=_TEST + "LifecycleDiagnosticExportTests/testLiveAndIncompleteCaptureCannotBeObserved",
    ),
    Mutation(
        name="web lifecycle evidence cleanup after export failure",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old="static func finish(root: URL, kind: Kind?, destination: URL?, sink: (Data) throws -> Void) throws {\n        defer { try? FileManager.default.removeItem(at: root) }",
        new="static func finish(root: URL, kind: Kind?, destination: URL?, sink: (Data) throws -> Void) throws {\n        // deliberately omitted fixture cleanup",
        test=_TEST
        + "LifecycleDiagnosticExportTests/testFinishEmitsOnceAndAlwaysCleansAfterArchiveOrOutputFailure",
    ),
    Mutation(
        name="web lifecycle evidence single summary emission",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old="do { try sink(summary(root: root, kind: kind, archiveFailed: archiveFailed)) }",
        new="do { try sink(summary(root: root, kind: kind, archiveFailed: archiveFailed)); try sink(summary(root: root, kind: kind, archiveFailed: archiveFailed)) }",
        test=_TEST
        + "LifecycleDiagnosticExportTests/testFinishEmitsOnceAndAlwaysCleansAfterArchiveOrOutputFailure",
    ),
    Mutation(
        name="web lifecycle evidence archive failure reporting",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old="if archiveFailed { throw Failure.archiveFailed }",
        new="if archiveFailed && destination == nil { throw Failure.archiveFailed }",
        test=_TEST
        + "LifecycleDiagnosticExportTests/testFinishEmitsOnceAndAlwaysCleansAfterArchiveOrOutputFailure",
    ),
    Mutation(
        name="web document fixture deletes evidence after browser retirement failure",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old="guard retirementFailures.isEmpty else { return }",
        new="// browser retirement evidence ignored",
        test=_TEST
        + "WebFrameIntegrationTests/testDocumentFixtureRetainsEvidenceWhenBrowserRetirementFails",
    ),
    Mutation(
        name="web document fixture deletes evidence after server retirement failure",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old="try await stopServer()",
        new="try? await stopServer()",
        test=_TEST
        + "WebFrameIntegrationTests/testDocumentFixtureRetainsEvidenceWhenServerRetirementFails",
    ),
    Mutation(
        name="web document fixture deletes evidence before server retirement completes",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old="try await stopServer()\n        guard retirementFailures.isEmpty else { return }\n        try FileManager.default.removeItem(at: root)",
        new="guard retirementFailures.isEmpty else { return }\n        try FileManager.default.removeItem(at: root)\n        try await stopServer()",
        test=_TEST
        + "WebFrameIntegrationTests/testDocumentFixtureRemovesRootOnlyAfterBothRetirementsSucceed",
    ),
    Mutation(
        name="web document fixture bypasses server retirement after browser failure",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old="try await stopServer()\n        guard retirementFailures.isEmpty else { return }",
        new="guard retirementFailures.isEmpty else { return }\n        try await stopServer()",
        test=_TEST
        + "WebFrameIntegrationTests/testDocumentFixtureRetainsEvidenceWhenBrowserRetirementFails",
    ),
    Mutation(
        name="web document budget witness ignores browser retirement failure",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old="let retirementFailures = await manager.closeAll()",
        new='let retirementFailures = (await manager.closeAll()) + [WebBrowserError.invalidWebOperation(reason: "injected retirement failure")]',
        test=_TEST
        + "WebFrameIntegrationTests/testLongDocumentsNestedPanelsAndFramesRemainScrollableAndActionable",
    ),
    Mutation(
        name="web late-exit fixture silently drops its injected delay",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old="            deadline=started+9",
        new="            deadline=started",
        test=_TEST + "WebCredentialLifecycleTests/testMCPSIGTERMAwaitsPermittedLateBrowserExit",
    ),
    Mutation(
        name="web document budget witness accepts unrelated browser errors",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old='return browserError == .invalidCDPResponse(reason: "inline border geometry: inline geometry capture deadline exceeded")',
        new='return true || browserError == .invalidCDPResponse(reason: "inline border geometry: inline geometry capture deadline exceeded")',
        test=_TEST + "WebFrameIntegrationTests/testDocumentBudgetRefusalRejectsUnrelatedErrors",
    ),
    Mutation(
        name="web login loses the saved task when the page reopens",
        path="Tests/VerdictUIWebTests/Fixtures/server.py",
        old="body = (fixture_root / path[1:]).read_bytes()",
        new="body = (fixture_root / path[1:]).read_bytes().replace(b'<script>', b\"<script>localStorage.removeItem('task-complete');\")",
        test=_TEST
        + "WebSessionIntegrationTests/testLoginTaskBadPasswordSecretRedactionAndProfilePersistence",
    ),
    Mutation(
        name="web HTTP login fixture mistakes its query for a route",
        path="Tests/VerdictUIWebTests/Fixtures/server.py",
        old="path = urllib.parse.urlsplit(self.path).path",
        new="path = self.path",
        test="Tests/test_web_fixture.py::test_loopback_fixture_starts_and_serves_without_reverse_dns",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="web orderly MCP witness truncates the valid shutdown allowance",
        path="Tests/VerdictUIWebTests/WebCredentialLifecycleTests.swift",
        old="let shutdownAllowance = crash ? 8 : WebSession.consumerShutdownGrace",
        new="let shutdownAllowance: TimeInterval = 8",
        test=_TEST + "WebCredentialLifecycleTests/testMCPSIGTERMAwaitsPermittedLateBrowserExit",
    ),
    Mutation(
        name="web persistent profile accidentally becomes incognito",
        path=_BASE + "HeadlessBrowser.swift",
        old='"--remote-debugging-port=0",',
        new='"--incognito",\n            "--remote-debugging-port=0",',
        test=_TEST + "WebSessionLifecycleTests/testHTTPStorageSurvivesImmediateCloseAndReopen",
    ),
    Mutation(
        name="web failed retirement is mistaken for completed cleanup",
        path=_BASE + "WebSession.swift",
        old="try await close()\n            return false",
        new="_ = try? await close()\n            return false",
        test=_TEST
        + "WebCredentialLifecycleTests/testFailedRetirementRetainsOwnerForRetryAcrossListOpenAndLookup",
    ),
    Mutation(
        name="web listing discards failed retirement ownership",
        path=_BASE + "WebSessionManager.swift",
        old="} catch {\n                    // Listing exposes available sessions only.",
        new="} catch {\n                    sessions.removeValue(forKey: key)\n                    // Listing exposes available sessions only.",
        test=_TEST
        + "WebCredentialLifecycleTests/testFailedRetirementRetainsOwnerForRetryAcrossListOpenAndLookup",
    ),
    Mutation(
        name="web reopen swallows failed retirement",
        path=_BASE + "WebSessionManager.swift",
        old="if try await session.isAvailable() {\n                guard !stopping else",
        new="if (try? await session.isAvailable()) == true {\n                guard !stopping else",
        test=_TEST
        + "WebCredentialLifecycleTests/testFailedRetirementRetainsOwnerForRetryAcrossListOpenAndLookup",
    ),
    Mutation(
        name="web lookup swallows failed retirement",
        path=_BASE + "WebSessionManager.swift",
        old="guard try await session.isAvailable() else",
        new="guard (try? await session.isAvailable()) == true else",
        test=_TEST
        + "WebCredentialLifecycleTests/testFailedRetirementRetainsOwnerForRetryAcrossListOpenAndLookup",
    ),
    Mutation(
        name="web credential resolver loses owner crash containment",
        path=_BASE + "WebCredentials.swift",
        old="private typealias CredentialProcess = GuardedProcess",
        new="private typealias CredentialProcess = OwnedCommandProcess",
        test=_TEST
        + "WebCredentialLifecycleTests/testMCPSIGKILLContainsCredentialDescendantAndPreservesSentinel",
    ),
    Mutation(
        name="web concurrent resolver close skips shared cleanup",
        path=_BASE + "WebCredentials.swift",
        old="if await closingTask.value.values.contains(false) { throw WebBrowserError.credentialUnavailable }",
        new="_ = closingTask",
        test=_TEST
        + "WebCredentialLifecycleTests/testCloseAndCancellationAwaitOwnedResolverGroupAndRefuseFallback",
    ),
    Mutation(
        name="web manager concurrent shutdown returns before shared cleanup",
        path=_BASE + "WebSessionManager.swift",
        old="if let closingTask { return await closingTask.value.compactMap(\\.failure) }",
        new="if closingTask != nil { return [] }",
        test=_TEST
        + "WebCredentialLifecycleTests/testManagerCoalescesConcurrentShutdownAndDrainsPendingAndOpenSessionsTogether",
    ),
    Mutation(
        name="web manager serializes independent profile close deadlines",
        path=_BASE + "WebSessionManager.swift",
        old="group.addTask { await Self.closeOutcome(profile: profile, session: session) }",
        new="let outcome = await Self.closeOutcome(profile: profile, session: session); group.addTask { outcome }",
        test=_TEST
        + "WebCredentialLifecycleTests/testManagerCoalescesConcurrentShutdownAndDrainsPendingAndOpenSessionsTogether",
    ),
    Mutation(
        name="guarded command silently truncates NUL arguments",
        path=_BASE + "OwnedCommandProcess.swift",
        old='!launchStrings.contains(where: { $0.contains("\\0") })',
        new="!launchStrings.isEmpty",
        test=_TEST + "GuardedProcessTests/testLaunchRejectsNulArgumentsAndNonFileURLs",
    ),
    Mutation(
        name="guarded command ignores working directory",
        path="Sources/VerdictUIProcessGuardian/ProcessGuardian.c",
        old="error = working_directory(&actions, directory);",
        new="(void)working_directory; error = directory[0] ? 0 : EINVAL;",
        test=_TEST
        + "GuardedProcessTests/testWorkingDirectoryEnvironmentBinaryStreamsAndActualExitCode",
    ),
    Mutation(
        name="guarded command drops standard error",
        path="Sources/VerdictUIProcessGuardian/ProcessGuardian.c",
        old="if (descriptors[fd] >= 0)\n                error = posix_spawn_file_actions_adddup2",
        new="if (descriptors[fd] >= 0 && fd != 2)\n                error = posix_spawn_file_actions_adddup2",
        test=_TEST
        + "GuardedProcessTests/testWorkingDirectoryEnvironmentBinaryStreamsAndActualExitCode",
    ),
    Mutation(
        name="guarded command accepts reused closed source descriptor",
        path="Sources/VerdictUIProcessGuardian/ProcessGuardian.c",
        old="standard_descriptors[fd] >= 0 && fcntl(standard_descriptors[fd], F_GETFD) < 0",
        new="standard_descriptors[fd] >= 0 && 0 && fcntl(standard_descriptors[fd], F_GETFD) < 0",
        test=_TEST
        + "GuardedProcessTests/testClosedDescriptorCannotBeReusedByEarlierStreamSnapshot",
    ),
    Mutation(
        name="guarded command closes borrowed descriptor instead of snapshot",
        path="Sources/VerdictUIProcessGuardian/ProcessGuardian.c",
        old="descriptors[fd] = fcntl(standard_descriptors[fd], F_DUPFD_CLOEXEC, 3);",
        new="descriptors[fd] = standard_descriptors[fd];",
        test=_TEST
        + "GuardedProcessTests/testWorkingDirectoryEnvironmentBinaryStreamsAndActualExitCode",
    ),
    Mutation(
        name="guarded command forgets caller grace",
        path="Sources/VerdictUIWeb/GuardedProcess.swift",
        old="if grace > 0 { _ = child.waitForExitEvent(timeout: grace) }",
        new="if grace > 0 { _ = child.waitForExitEvent(timeout: 0) }",
        test=_TEST + "GuardedProcessTests/testCallerGraceAllowsDelayedFlushAndReturnsCommandStatus",
    ),
    Mutation(
        name="guarded command ignores lost guardian",
        path="Sources/VerdictUIWeb/GuardedProcess.swift",
        old="guard try guardian.status() == nil else {",
        new="guard try guardian.status() == nil || true else {",
        test=_TEST
        + "GuardedProcessTests/testLostGuardianMakesRunningCommandUnavailableUntilCleanup",
    ),
    Mutation(
        name="guarded command substitutes guardian exit status",
        path="Sources/VerdictUIWeb/GuardedProcess.swift",
        old="completedCode = code",
        new="completedCode = code == 0 ? 0 : 137",
        test=_TEST
        + "GuardedProcessTests/testWorkingDirectoryEnvironmentBinaryStreamsAndActualExitCode",
    ),
    Mutation(
        name="guardian truncates requested graceful shutdown",
        path=_BASE + "GuardedProcess.swift",
        old="try child.requestBrowserTermination()",
        new="lifetime.closeWriter()",
        test=_TEST
        + "BrowserCrashGuardianTests/testRequestedGraceAllowsBrowserToFlushBeforeGroupCleanup|"
        + _TEST
        + "BrowserCrashGuardianTests/testNormalTERMAllowsBrowserToCoordinateChildFlush",
    ),
    Mutation(
        name="guardian ignores parent death with leaked writer",
        path="Sources/VerdictUIProcessGuardian/ProcessGuardian.c",
        old="if (getppid() != parent) return 1;",
        new="if (getppid() != parent && 0) return 1;",
        test=_TEST + "BrowserCrashGuardianTests/testLeakedWriterCannotDefeatActualParentDeath",
    ),
    Mutation(
        name="guardian ignores sole writer EOF",
        path="Sources/VerdictUIProcessGuardian/ProcessGuardian.c",
        old="return read(lifetime, &byte, 1) <= 0;",
        new="(void)read(lifetime, &byte, 1); return 0;",
        test=_TEST
        + "BrowserCrashGuardianTests/testSoleLifetimeWriterCloseCleansGroupWhileParentStaysAlive",
    ),
    Mutation(
        name="guardian kills leader without browser group",
        path="Sources/VerdictUIProcessGuardian/ProcessGuardian.c",
        old="(void)kill(0, SIGKILL);",
        new="(void)kill(getpid(), SIGKILL);",
        test=_TEST
        + "BrowserCrashGuardianTests/testParentSIGKILLReapsBrowserGroupWithoutTouchingUnrelatedSentinel",
    ),
    Mutation(
        name="guardian leaves high inherited descriptors open",
        path="Sources/VerdictUIProcessGuardian/ProcessGuardian.c",
        old="fd < descriptor_limit; ++fd",
        new="fd < descriptor_limit && fd < 64; ++fd",
        test=_TEST
        + "BrowserCrashGuardianTests/testDescriptorsAboveLoweredLimitAreClosedAndBrowserSignalsReset",
    ),
    Mutation(
        name="guardian browser escapes owned group",
        path="Sources/VerdictUIProcessGuardian/ProcessGuardian.c",
        old="posix_spawnattr_setpgroup(&attributes, guardian)",
        new="posix_spawnattr_setpgroup(&attributes, guardian - guardian)",
        test=_TEST
        + "BrowserCrashGuardianTests/testParentSIGKILLReapsBrowserGroupWithoutTouchingUnrelatedSentinel",
    ),
    Mutation(
        name="guardian browser keeps ignored signal handlers",
        path="Sources/VerdictUIProcessGuardian/ProcessGuardian.c",
        old="POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF |",
        new="POSIX_SPAWN_SETPGROUP |",
        test=_TEST
        + "BrowserCrashGuardianTests/testDescriptorsAboveLoweredLimitAreClosedAndBrowserSignalsReset",
    ),
    Mutation(
        name="guardian browser keeps blocked signal mask",
        path="Sources/VerdictUIProcessGuardian/ProcessGuardian.c",
        old="POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT",
        new="POSIX_SPAWN_CLOEXEC_DEFAULT",
        test=_TEST
        + "BrowserCrashGuardianTests/testDescriptorsAboveLoweredLimitAreClosedAndBrowserSignalsReset",
    ),
    Mutation(
        name="guardian browser first exit leaves writer open",
        path="Sources/VerdictUIWeb/GuardedProcess.swift",
        old="exitSource.setEventHandler { lifetime.closeWriter() }",
        new="exitSource.setEventHandler { _ = lifetime }",
        test=_TEST
        + "BrowserCrashGuardianTests/testBrowserFirstExitCleansDescendantAndReleasesRetainedChildren",
    ),
    Mutation(
        name="guardian cleanup forgets permanent ownership loss",
        path="Sources/VerdictUIWeb/OwnedCommandProcess.swift",
        old="if errno == ECHILD { reaped = true; retentionFailure = ECHILD }",
        new="if errno == ECHILD { reaped = true }",
        test=_TEST
        + "BrowserCrashGuardianTests/testAlreadyReapedGuardianRevokesSignalAuthorityEvenWithCachedExit|"
        + _TEST
        + "BrowserCrashGuardianTests/testAlreadyReapedBrowserRefusesNormalTERMDespiteCachedExit",
    ),
    Mutation(
        name="guardian hides failed cleanup after browser exit",
        path=_BASE + "HeadlessBrowser.swift",
        old="guard process.isRunning else { try process.finish(); return }",
        new="guard process.isRunning else { return }",
        test=_TEST
        + "BrowserProcessIdentityTests/testCleanupFailurePropagatesEvenWhenBrowserAlreadyExited",
    ),
]
