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
]
