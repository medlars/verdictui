"""Real-product transport and project coverage guard witnesses."""

from mutation_catalog_types import Mutation

MUTATIONS: list[Mutation] = [
    Mutation(
        name="live requests allow non-finite or unbounded observation deadlines",
        path="Sources/VerdictUICLICore/LiveRuntime.swift",
        old="guard timeout.isFinite, timeout > 0, timeout <= 60 else {",
        new="guard true else {",
        test="LiveRuntimeTests/testInvalidTargetsAndEmptyExpectationsAreRejected",
    ),
    Mutation(
        name="live requests accept empty outcome assertions",
        path="Sources/VerdictUICLICore/LiveRuntime.swift",
        old="if let expectText, expectText.isEmpty {",
        new="if let expectText, expectText.isEmpty && false {",
        test="LiveRuntimeTests/testInvalidTargetsAndEmptyExpectationsAreRejected",
    ),
    Mutation(
        name="live MCP truncates fractional process identifiers",
        path="Sources/VerdictUICLICore/ExtendedMCP.swift",
        old="let exact = Int32(exactly: number)",
        new="let exact = Int32(exactly: number.rounded(.towardZero))",
        test="LiveRuntimeTests/testMCPRejectsLossyAndWrongTypeArguments",
    ),
    Mutation(
        name="live outcomes pass without observing expected state",
        path="Sources/VerdictUICLICore/LiveRuntime.swift",
        old="if let expected, !containsText(tree, expected) {",
        new="if let expected, !containsText(tree, expected) && false {",
        test="LiveRuntimeTests/testPostedInputDoesNotSatisfyUnobservedOutcome",
    ),
    Mutation(
        name="live denied input is treated as successfully posted",
        path="Sources/VerdictUICLICore/LiveRuntime.swift",
        old="do { try perform() } catch { throw Failure.unavailable }",
        new="do { try perform() } catch { /* deliberately swallowed */ }",
        test="LiveRuntimeTests/testDeniedInputProducesNoVerdictAndDoesNotLeakValue",
    ),
    Mutation(
        name="web actions accept missing node targets",
        path="Sources/VerdictUICLICore/WebRuntime.swift",
        old="guard let node = request.node, !node.isEmpty else {",
        new='guard let node = Optional(request.node ?? "") else {',
        test="WebRuntimeTests/testCredentialAndActionBoundaries",
    ),
    Mutation(
        name="web credential actions accept literal secret text",
        path="Sources/VerdictUICLICore/WebRuntime.swift",
        old="!reference.isEmpty, request.text == nil else {",
        new="!reference.isEmpty else {",
        test="WebRuntimeTests/testCredentialAndActionBoundaries",
    ),
    Mutation(
        name="web type actions silently ignore credential references",
        path="Sources/VerdictUICLICore/WebRuntime.swift",
        old="guard let text = request.text, request.credential == nil else {",
        new="guard let text = request.text else {",
        test="WebRuntimeTests/testCredentialAndActionBoundaries",
    ),
    Mutation(
        name="project checks accept empty and duplicated declarations",
        path="Sources/VerdictUICLICore/ProjectChecks.swift",
        old="guard !manifest.checks.isEmpty, manifest.checks.count <= 100,\n              Set(manifest.checks.map(\\.name)).count == manifest.checks.count else {",
        new="guard true else {",
        test="ProjectChecksTests/testEmptyDuplicateAndUnknownDeclarationsAreRejected",
    ),
    Mutation(
        name="project checks accept invalid kinds and empty expectations",
        path="Sources/VerdictUICLICore/ProjectChecks.swift",
        old='guard !check.name.isEmpty, ["scenario", "web", "appkit", "live"].contains(check.kind),\n                  check.expectText?.isEmpty != true else {',
        new="guard true else {",
        test="ProjectChecksTests/testEmptyDuplicateAndUnknownDeclarationsAreRejected",
    ),
    Mutation(
        name="project checks certify a different consumer scenario",
        path="Sources/VerdictUICLICore/ProjectChecks.swift",
        old="guard verdict.scenario == scenario, (verdict.status == .pass) == (result.code == 0) else {",
        new="guard (verdict.status == .pass) == (result.code == 0) else {",
        test="ProjectChecksTests/testConsumerVerdictPreservesFailureAndISODate",
    ),
    Mutation(
        name="project checks lose consumer ISO timestamp decoding",
        path="Sources/VerdictUICLICore/ProjectChecks.swift",
        old="decoder.dateDecodingStrategy = .iso8601",
        new="decoder.dateDecodingStrategy = .deferredToDate",
        test="ProjectChecksTests/testConsumerVerdictPreservesFailureAndISODate",
    ),
    Mutation(
        name="bounded check subprocess accepts oversized completed output",
        path="Sources/VerdictUICLICore/BoundedCommand.swift",
        old="guard data.count <= limit else { throw Failure.excessiveOutput }",
        new="_ = data.count <= limit",
        test="ProjectChecksTests/testSubprocessBoundsOutputAndTime",
    ),
    Mutation(
        name="server startup force unwraps default signal handler",
        path="Sources/VerdictUICLICore/RuntimeShutdown.swift",
        old="private var previous: [(Int32, sig_t?)] = []",
        new="private var previous: [(Int32, sig_t)] = []",
        test="MCPLatencyTests/testWarmVerifyRoundTripMeetsTheLatencyBudget",
    ),
]
