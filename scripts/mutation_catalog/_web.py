"""Web-engine guards and their real browser / pure CDP witnesses."""

from mutation_catalog_types import Mutation, Runner

_BASE = "Sources/VerdictUIWeb/"
_TEST = "VerdictUIWebTests."

MUTATIONS: list[Mutation] = [
    Mutation(
        name="guardian truncates requested graceful shutdown",
        path=_BASE + "BrowserProcessIdentity.swift",
        old="if value == SIGTERM { try browser.requestBrowserTermination() }",
        new="if value == SIGTERM { lifetime.closeWriter() }",
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
        path="Sources/VerdictUIWeb/BrowserProcessIdentity.swift",
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
    Mutation(
        name="web inline enrichment skips cumulative candidate reservation",
        path=_BASE + "WebInlineGeometry.swift",
        old="        try budget.reserveCandidates(candidates.count)",
        new="        try budget.reserveCandidates(0)",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testInlineEnrichmentRejectsExhaustedCandidatesBeforeRemoteCommands|"
        + _TEST
        + "WebFrameIntegrationTests/testRealInlineSnapshotHonorsCumulativeCandidateBoundaryBeforeRemoteWork",
    ),
    Mutation(
        name="web frame coherence does not retry stale capture",
        path=_BASE + "WebSession.swift",
        old="for attempt in 0..<3 {",
        new="for attempt in 0..<1 {",
        test=_TEST
        + "WebFrameIntegrationTests/testFrameAppearingAfterMainSnapshotMustRecaptureItsActualOwner",
    ),
    Mutation(
        name="web frame coherence retries terminal errors",
        path=_BASE + "WebSession.swift",
        old="} catch CaptureInconsistency.missingOwner {",
        new="} catch {",
        test=_TEST
        + "WebFrameIntegrationTests/testFrameCaptureRetryLimitDeadlineCancellationAndTerminalFailures",
    ),
    Mutation(
        name="web frame coherence resets shared deadline",
        path=_BASE + "WebSession.swift",
        old="var budget = WebInlineGeometry.Budget(deadline: deadline)",
        new="var budget = WebInlineGeometry.Budget(deadline: .now + .seconds(10))",
        test=_TEST
        + "WebFrameIntegrationTests/testFrameCaptureRetryLimitDeadlineCancellationAndTerminalFailures",
    ),
    Mutation(
        name="web frame coherence ignores absent owners",
        path=_BASE + "WebSession.swift",
        old="guard found else { throw CaptureInconsistency.missingOwner }",
        new="guard found || !found else { throw CaptureInconsistency.missingOwner }",
        test=_TEST
        + "WebFrameIntegrationTests/testFrameAppearingAfterMainSnapshotMustRecaptureItsActualOwner",
    ),
    Mutation(
        name="web frame coherence returns partial tree after exhaustion",
        path=_BASE + "WebSession.swift",
        old='throw WebBrowserError.invalidCDPResponse(reason: "embedded frame owner remained absent after 3 coherent capture attempts")',
        new='return CapturedTree(tree: SemanticNode(id: "partial", role: .container, frame: viewport), retried: true)',
        test=_TEST
        + "WebFrameIntegrationTests/testFrameCaptureRetryLimitDeadlineCancellationAndTerminalFailures",
    ),
    Mutation(
        name="web frame coherence forgets retry provenance",
        path=_BASE + "WebSession.swift",
        old="retried: attempt > 0",
        new="retried: attempt > 3",
        test=_TEST
        + "WebFrameIntegrationTests/testFrameAppearingAfterMainSnapshotMustRecaptureItsActualOwner",
    ),
    Mutation(
        name="web frame coherence reuses prior stability confirmations",
        path=_BASE + "WebSession.swift",
        old="if capture.retried { previous = nil; stable = 0 }",
        new="if capture.retried { previous = capture.tree }",
        test=_TEST
        + "WebFrameIntegrationTests/testRecoveredCaptureDiscardsPreRaceStabilityConfirmations",
    ),
    Mutation(
        name="web loopback fixture waits for reverse DNS before listening",
        path="Tests/VerdictUIWebTests/Fixtures/server.py",
        old="socketserver.TCPServer.server_bind(self)",
        new="super().server_bind()",
        test="Tests/test_web_fixture.py::test_loopback_fixture_starts_and_serves_without_reverse_dns",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="web fixture ignores its configured interpreter",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old='if let configured = environment["VERDICTUI_TEST_PYTHON"]',
        new='if let configured = environment["VERDICTUI_IGNORED_PYTHON"]',
        test=_TEST
        + "WebFrameIntegrationTests/testConfiguredFixtureInterpreterReportsExitAndBoundedOutput",
    ),
    Mutation(
        name="web fixture accepts an invalid configured interpreter",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old='guard configured.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: configured) else',
        new="guard true else",
        test=_TEST
        + "WebFrameIntegrationTests/testFixtureInterpreterUsesPATHAndRefusesInvalidConfiguration",
    ),
    Mutation(
        name="web fixture selects a missing PATH interpreter",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old="if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }",
        new="if true { return candidate }",
        test=_TEST
        + "WebFrameIntegrationTests/testFixtureInterpreterUsesPATHAndRefusesInvalidConfiguration",
    ),
    Mutation(
        name="web fixture emits unbounded startup diagnostics",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old="reader.read(upToCount: 4096)",
        new="reader.readToEnd()",
        test=_TEST
        + "WebFrameIntegrationTests/testConfiguredFixtureInterpreterReportsExitAndBoundedOutput",
    ),
    Mutation(
        name="web fixture stops the server after handing it to its caller",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old="return (fixtureProcess, port)",
        new="try await fixtureProcess.stop(); return (fixtureProcess, port)",
        test=_TEST
        + "WebFrameIntegrationTests/testSameAndCrossOriginFramesRenderAndActWithCorrectRootCoordinates",
    ),
    Mutation(
        name="owned process ignores its requested working directory",
        path=_BASE + "OwnedCommandProcess.swift",
        old="try checked(addWorkingDirectory(&actions, path: directory.path))",
        new="try checked(0)",
        test=_TEST
        + "OwnedCommandProcessTests/testSpawnUsesRequestedWorkingDirectoryWithoutChangingParent",
    ),
    Mutation(
        name="web page commands omit their flattened session identity",
        path=_BASE + "CDPTransport.swift",
        old="params: params, sessionId: sessionID)",
        new="params: params, sessionId: nil)",
        test=_TEST + "CDPTransportTests/testPageSessionEnvelopeAndNetworkSettlingIsolation",
    ),
    Mutation(
        name="web network activity is ignored while settling",
        path=_BASE + "CDPTransport.swift",
        old="inFlightNetwork[sessionID]?.count ?? 0",
        new="0",
        test=_TEST + "CDPTransportTests/testPageSessionEnvelopeAndNetworkSettlingIsolation",
    ),
    Mutation(
        name="web redaction leaves reflected credential literals",
        path=_BASE + "WebRedaction.swift",
        old='result = result.replacingOccurrences(of: secret, with: "[REDACTED]")',
        new="result = result.replacingOccurrences(of: secret, with: secret)",
        test=_TEST + "DOMSnapshotAssemblyTests/testRedactionRemovesReflectionsAndSensitiveURLs",
    ),
    Mutation(
        name="web redaction includes authentication query strings",
        path=_BASE + "WebRedaction.swift",
        old="parts.query = nil",
        new="parts.query = url.query",
        test=_TEST + "DOMSnapshotAssemblyTests/testRedactionRemovesReflectionsAndSensitiveURLs",
    ),
    Mutation(
        name="web credential references bypass resolution",
        path=_BASE + "WebCredentials.swift",
        old="return configured\n    }",
        new="return reference\n    }",
        test=_TEST + "WebCredentialsTests/testReferenceResolutionDoesNotTreatReferenceAsSecret",
    ),
    Mutation(
        name="web declared onepassword reference silently uses fallback",
        path=_BASE + "WebCredentials.swift",
        old='return try await runOnePassword(["read", opReference, "--no-newline"], executable: onePassword)',
        new='do { return try await runOnePassword(["read", opReference, "--no-newline"], executable: onePassword) } catch { return sharedValue(key) ?? "unresolved" }',
        test=_TEST + "WebCredentialsTests/testSharedFileFallbackAndOnePasswordReferencePrecedence",
    ),
    Mutation(
        name="web same-pid lock contention ignores the kernel lock",
        path=_BASE + "ProfileLock.swift",
        old="guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else",
        new="guard descriptor >= 0 else",
        test=_TEST
        + "ProfileLockTests/testKernelLockRejectsEvenAnEmptyPidfileAndReleaseIsIdempotent",
    ),
    Mutation(
        name="web profile live-owner liveness gate is bypassed",
        path=_BASE + "ProfileLock.swift",
        old="if let holder = readHolder(at: path), liveness(holder)",
        new="if let holder = readHolder(at: path), !liveness(holder)",
        test=_TEST + "ProfileLockTests/testALiveHoldersLockIsNeverStolen",
    ),
    Mutation(
        name="web password fields allow literal credentials",
        path=_BASE + "WebSession.swift",
        old='guard node.attributes["web.password"] != .bool(true) else',
        new='guard node.attributes["web.password"] != .bool(false) else',
        test=_TEST
        + "WebSessionIntegrationTests/testLoginTaskBadPasswordSecretRedactionAndProfilePersistence",
    ),
    Mutation(
        name="web normal session close omits Chrome profile flush",
        path=_BASE + "WebSession.swift",
        old='transport.send(method: "Browser.close", timeout: .seconds(2))',
        new='transport.send(method: "Browser.getVersion", timeout: .seconds(2))',
        test=_TEST
        + "WebCredentialLifecycleTests/testSessionCloseFlushesBeforeDisconnectAndProfileReleaseWithoutAReply",
    ),
    Mutation(
        name="web orderly exit waits on recycled pid instead of owned child",
        path=_BASE + "HeadlessBrowser.swift",
        old="await Self.awaitOwnedDeath(process: process, within: grace)\n    }",
        new="await Self.awaitDeath(pid: pid, within: grace)\n    }",
        test=_TEST
        + "WebCredentialLifecycleTests/testSessionCloseFlushesBeforeDisconnectAndProfileReleaseWithoutAReply",
    ),
    Mutation(
        name="web unmet action expectation is accepted",
        path=_BASE + "WebSession.swift",
        old='rule: "web-expectation", severity: .error',
        new='rule: "web-expectation", severity: .warning',
        test=_TEST
        + "WebSessionIntegrationTests/testLoginTaskBadPasswordSecretRedactionAndProfilePersistence",
    ),
    Mutation(
        name="web typing appends instead of replacing selected field text",
        path=_BASE + "WebSession.swift",
        old='parameters["commands"] = .array([.string("selectAll")])',
        new='parameters["commands"] = .array([])',
        test=_TEST
        + "WebSessionIntegrationTests/testLoginTaskBadPasswordSecretRedactionAndProfilePersistence",
    ),
    Mutation(
        name="web named onepassword item loses to environment fallback",
        path=_BASE + "WebCredentials.swift",
        old='return try await runOnePassword(["item", "get", reference, "--fields", "label=password", "--reveal"], executable: onePassword)',
        new='let resolved = try await runOnePassword(["item", "get", reference, "--fields", "label=password", "--reveal"], executable: onePassword); return configured ?? resolved',
        test=_TEST + "WebCredentialsTests/testOnePasswordNamedItemWinsBeforeSharedFallback",
    ),
    Mutation(
        name="web dead owned process signals a recycled live pid on terminate",
        path=_BASE + "HeadlessBrowser.swift",
        old="guard process.isRunning else { try process.finish(); return }",
        new="guard pid > 0 else { return }",
        test=_TEST
        + "BrowserProcessIdentityTests/testReusedLivePIDDoesNotAuthorizeTerminatingADeadChild",
    ),
    Mutation(
        name="web dead owned process signals a recycled live pid on deinit",
        path=_BASE + "HeadlessBrowser.swift",
        old="if process.isRunning { try? process.signal(SIGKILL) }",
        new="if pid > 0 { try? process.signal(SIGKILL) }",
        test=_TEST
        + "BrowserProcessIdentityTests/testReusedLivePIDDoesNotAuthorizeTerminatingADeadChild",
    ),
    Mutation(
        name="web availability trusts a recycled live pid",
        path=_BASE + "HeadlessBrowser.swift",
        old="func isRunning() -> Bool { process.isRunning }",
        new="func isRunning() -> Bool { ProcessLiveness.isAlive(pid) }",
        test=_TEST
        + "BrowserProcessIdentityTests/testReusedLivePIDDoesNotAuthorizeTerminatingADeadChild",
    ),
    Mutation(
        name="web dead session retains transport and profile ownership",
        path=_BASE + "WebSession.swift",
        old="guard await browser.isRunning() else",
        new="guard browser.pid > 0 else",
        test=_TEST + "WebSessionIntegrationTests/testBrowserDownIsUnavailableAndReleasesProfile",
    ),
    Mutation(
        name="web session list advertises a dead browser",
        path=_BASE + "WebSessionManager.swift",
        old="if await session.isAvailable() { result.append",
        new="if !key.isEmpty { result.append",
        test=_TEST + "WebSessionIntegrationTests/testBrowserDownIsUnavailableAndReleasesProfile",
    ),
    Mutation(
        name="web reopen navigates a dead session",
        path=_BASE + "WebSessionManager.swift",
        old="if await session.isAvailable() {\n                try await session.navigate",
        new="if !profile.isEmpty {\n                try await session.navigate",
        test=_TEST + "WebSessionIntegrationTests/testBrowserDownIsUnavailableAndReleasesProfile",
    ),
    Mutation(
        name="web session lookup bypasses dead child eviction",
        path=_BASE + "WebSessionManager.swift",
        old="guard await session.isAvailable() else",
        new="guard !profile.isEmpty else",
        test=_TEST + "WebSessionIntegrationTests/testBrowserDownIsUnavailableAndReleasesProfile",
    ),
    Mutation(
        name="owned process event wait returns before an exit event",
        path=_BASE + "OwnedCommandProcess.swift",
        old="_ = completion.wait(timeout: .now() + timeout)",
        new="_ = timeout",
        test=_TEST + "OwnedCommandProcessTests/testExitEventTimesOutThenObservesExitWithoutReaping",
    ),
    Mutation(
        name="web resolver shutdown forgets its active owned groups",
        path=_BASE + "WebCredentials.swift",
        old="let pending = operations",
        new="let pending: [UUID: Operation] = [:]",
        test=_TEST
        + "WebCredentialLifecycleTests/testCloseAndCancellationAwaitOwnedResolverGroupAndRefuseFallback",
    ),
    Mutation(
        name="web resolver task cancellation is not forwarded",
        path=_BASE + "WebCredentials.swift",
        old="} onCancel: { worker.cancel() }",
        new="} onCancel: {}",
        test=_TEST
        + "WebCredentialLifecycleTests/testCloseAndCancellationAwaitOwnedResolverGroupAndRefuseFallback",
    ),
    Mutation(
        name="web closed resolver returns an environment fallback",
        path=_BASE + "WebCredentials.swift",
        old="public func resolve(_ reference: String) async throws -> String {\n        guard !closed, !Task.isCancelled else",
        new="public func resolve(_ reference: String) async throws -> String {\n        guard !Task.isCancelled else",
        test=_TEST
        + "WebCredentialLifecycleTests/testClosedResolverRefusesFallbackAndOversizedOutputIsRejected",
    ),
    Mutation(
        name="web resolver closing in flight falls back to another credential",
        path=_BASE + "WebCredentials.swift",
        old="if closed || Task.isCancelled { throw WebBrowserError.credentialUnavailable }",
        new="if Task.isCancelled { throw WebBrowserError.credentialUnavailable }",
        test=_TEST
        + "WebCredentialLifecycleTests/testCloseAndCancellationAwaitOwnedResolverGroupAndRefuseFallback",
    ),
    Mutation(
        name="web credential output exceeds the bounded field size",
        path=_BASE + "WebCredentials.swift",
        old="guard output.count + chunk.count <= 65_536 else",
        new="guard output.count + chunk.count <= 131_072 else",
        test=_TEST
        + "WebCredentialLifecycleTests/testClosedResolverRefusesFallbackAndOversizedOutputIsRejected",
    ),
    Mutation(
        name="web session shutdown leaves an active credential group behind",
        path=_BASE + "WebSession.swift",
        old="try await credentials.close()",
        new="_ = credentials",
        test=_TEST
        + "WebCredentialLifecycleTests/testMCPSIGTERMAwaitsInFlightCredentialGroupBeforeExit",
    ),
    Mutation(
        name="web concurrent close returns before existing shutdown completes",
        path=_BASE + "WebSession.swift",
        old="if let closingTask { return try await closingTask.value }",
        new="if closingTask != nil { return }",
        test=_TEST
        + "WebCredentialLifecycleTests/testSessionCloseAwaitsCredentialLookupAndReleasesProfile",
    ),
    Mutation(
        name="web shutdown omits opening browser ownership",
        path=_BASE + "WebSessionManager.swift",
        old="let pending = launches",
        new="let pending: [String: Task<WebSession, Error>] = [:]",
        test=_TEST
        + "WebOpeningLifecycleTests/testOpeningCancellationAndCloseAllAwaitTheUnpublishedBrowser",
    ),
    Mutation(
        name="web caller cancellation does not cancel its opening browser",
        path=_BASE + "WebSessionManager.swift",
        old="} onCancel: { launch.cancel() }",
        new="} onCancel: {}",
        test=_TEST
        + "WebOpeningLifecycleTests/testOpeningCancellationAndCloseAllAwaitTheUnpublishedBrowser",
    ),
    Mutation(
        name="web failed discovery leaves its exact launched child alive",
        path=_BASE + "HeadlessBrowser.swift",
        old="owned.signal(SIGKILL)",
        new="_ = owned",
        test=_TEST
        + "WebOpeningLifecycleTests/testMCPSIGTERMAwaitsBrowserStillDiscoveringItsEndpoint",
    ),
]
