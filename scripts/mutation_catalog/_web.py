"""Web-engine guards and their real browser / pure CDP witnesses."""

from mutation_catalog_types import Mutation

_BASE = "Sources/VerdictUIWeb/"
_TEST = "VerdictUIWebTests."

MUTATIONS: list[Mutation] = [
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
        name="web orphaned embedded document is silently ignored",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="guard visited.count == trees.count else",
        new="guard trees.count >= visited.count else",
        test=_TEST + "DOMSnapshotAssemblyTests/testOrphanedEmbeddedDocumentIsUnavailable",
    ),
    Mutation(
        name="web DOM snapshot mismatch becomes an empty observed tree",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='else { throw malformed("mismatched or oversized node columns") }',
        new="else { return [] }",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web invalid topology becomes an empty observed tree",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='else { throw malformed("invalid parent topology") }',
        new="else { return [] }",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web invalid backend identity becomes empty observed content",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='throw malformed("invalid parent topology or backend identity")',
        new="return []",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web malformed attribute pairs are silently accepted",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='else { throw malformed("odd attribute column") }',
        new="else { return [] }",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web malformed layout indices silently disappear",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='throw malformed("invalid or duplicate layout index")',
        new="return []",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web missing computed styles become unobserved content",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='else { throw malformed("missing computed styles") }',
        new="else { return [] }",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web malformed text box index becomes unobserved content",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='else { throw malformed("invalid text box index") }',
        new="else { return [] }",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web malformed string index becomes empty text",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='else { throw malformed("string index out of range") }',
        new='else { return "" }',
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web negative geometry is normalized instead of refused",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='else { throw malformed("negative rectangle extent") }',
        new="else { return Rect(x: 0, y: 0, width: 0, height: 0) }",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web generic scaffolding counts as probe evidence",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='id: role == .container ? "" : (frameID == "main"',
        new='id: (frameID == "main"',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testHiddenAncestorHidesTextAndEmptyContainersDoNotCountAsEvidence",
    ),
    Mutation(
        name="web hidden ancestors expose child content",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="if !visible { descendants = descendants.map(hidden) }",
        new="if visible { descendants = descendants.map(hidden) }",
        test=_TEST + "DOMSnapshotAssemblyTests/testSnapshotRolesGeometryTextAndMetrics",
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
        name="web custom roles expose reflected credentials",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="role = .custom(WebRedaction.clean(raw, secrets: secrets))",
        new="role = .custom(raw)",
        test=_TEST + "DOMSnapshotAssemblyTests/testCredentialReflectedIntoCustomRoleIsRedacted",
    ),
    Mutation(
        name="web dead owned process signals a recycled live pid on terminate",
        path=_BASE + "HeadlessBrowser.swift",
        old="guard process.isRunning else { return }",
        new="guard pid > 0 else { return }",
        test=_TEST
        + "BrowserProcessIdentityTests/testReusedLivePIDDoesNotAuthorizeTerminatingADeadChild",
    ),
    Mutation(
        name="web dead owned process signals a recycled live pid on deinit",
        path=_BASE + "HeadlessBrowser.swift",
        old="if process.isRunning { process.signal(SIGKILL) }",
        new="if pid > 0 { process.signal(SIGKILL) }",
        test=_TEST
        + "BrowserProcessIdentityTests/testReusedLivePIDDoesNotAuthorizeTerminatingADeadChild",
    ),
    Mutation(
        name="web compact tree drops control accessible names",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="} ?? accessibleName,",
        new="},",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testControlNameSurvivesCompactTextAndNeverUsesValueChildren",
    ),
    Mutation(
        name="web field descendants expose existing values",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='if role == .textField || tag == "input" || tag == "textarea" { descendants = [] }',
        new='if tag == "not-an-input" { descendants = [] }',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testControlNameSurvivesCompactTextAndNeverUsesValueChildren",
    ),
    Mutation(
        name="web aria labelledby loses naming priority",
        path=_BASE + "DOMAccessibleNames.swift",
        old='if let references = attrs["aria-labelledby"]',
        new='if let references = attrs["not-aria-labelledby"]',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testAssociatedLabelsAndAriaNamesHaveDeterministicPriority",
    ),
    Mutation(
        name="web explicit labels lose control association",
        path=_BASE + "DOMAccessibleNames.swift",
        old='if let target = attributes[index]["for"]',
        new='if let target = attributes[index]["not-for"]',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testAssociatedLabelsAndAriaNamesHaveDeterministicPriority",
    ),
    Mutation(
        name="web wrapping labels lose control association",
        path=_BASE + "DOMAccessibleNames.swift",
        old='if tags[ancestor] == "label",',
        new='if tags[ancestor] == "not-label",',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testAssociatedLabelsAndAriaNamesHaveDeterministicPriority",
    ),
    Mutation(
        name="web field values become parent label content",
        path=_BASE + "DOMAccessibleNames.swift",
        old='contents[index] = ""',
        new='contents[index] += ""',
        test=_TEST + "DOMSnapshotAssemblyTests/testAccessibleLabelsExcludeEditableValues",
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
