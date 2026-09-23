"""Workbench trust boundary and daemon resource-limit witnesses."""

from mutation_catalog_types import Mutation

MUTATIONS: list[Mutation] = [
    Mutation(
        name="workbench origin check ignores scheme authority and query",
        path="Sources/VerdictUIWorkbenchCore/WorkbenchBridge.swift",
        old='guard isMainFrame, let candidate, candidate.isFileURL, candidate.query == nil, candidate.fragment == nil,\n              candidate.host == nil || candidate.host == "" || candidate.host == "localhost" else { return false }\n        return candidate.standardizedFileURL == page',
        new="return isMainFrame && candidate?.path == page.path",
        test="WorkbenchStoreTests/testBridgeAcceptsOnlyTheBundledLocalMainFrame",
    ),
    Mutation(
        name="workbench accepts subframe messages",
        path="Sources/VerdictUIWorkbenchCore/WorkbenchBridge.swift",
        old="guard isMainFrame, let candidate,",
        new="guard let candidate,",
        test="WorkbenchStoreTests/testBridgeAcceptsOnlyTheBundledLocalMainFrame",
    ),
    Mutation(
        name="workbench allows another bundled path",
        path="Sources/VerdictUIWorkbenchCore/WorkbenchBridge.swift",
        old="return candidate.standardizedFileURL == page",
        new="return true",
        test="WorkbenchStoreTests/testBridgeAcceptsOnlyTheBundledLocalMainFrame",
    ),
    Mutation(
        name="daemon never expires silent clients",
        path="Sources/VerdictUICLICore/DaemonTransport.swift",
        old="guard ContinuousClock.now < idleDeadline, ContinuousClock.now < frameDeadline else { return }",
        new="_ = idleDeadline; _ = frameDeadline",
        test="DaemonTransportTests/testStalledAndOversizedClientsCannotBlockFollowingClients",
    ),
    Mutation(
        name="daemon answers oversized complete frames",
        path="Sources/VerdictUICLICore/DaemonTransport.swift",
        old="guard line.count <= maximumFrameBytes else { return }",
        new="guard true else { return }",
        test="DaemonTransportTests/testStalledAndOversizedClientsCannotBlockFollowingClients",
    ),
]
