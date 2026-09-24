"""Mutation witnesses for consumer broker freshness and restart invariants."""

from mutation_catalog_types import Mutation

MUTATIONS: list[Mutation] = [
    Mutation(
        name="source changes do not restart the consumer",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="if generation != before || child == nil {",
        new="if child == nil {",
        test="ProjectRunnerBrokerTests/testUnchangedRequestsReuseChildAndSourceEditRestartsIt",
    ),
    Mutation(
        name="mixed build generations certify a result",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="guard sourceBefore == (try fingerprint(includeExecutable: false)) else {",
        new="guard true else {",
        test="ProjectRunnerBrokerTests/testSourceMutationDuringBuildCannotCertifyMixedGeneration",
    ),
    Mutation(
        name="consumer restart omits MCP initialization",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="_ = try exchange(initialization, expectsReply: true)",
        new="_ = initialization",
        test="ProjectRunnerBrokerTests/testUnchangedRequestsReuseChildAndSourceEditRestartsIt",
    ),
    Mutation(
        name="a mid-request source change serves a stale verdict",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="guard generation == (try fingerprint()) else {",
        new="guard true else {",
        test="ProjectRunnerBrokerTests/testSourceChangeDuringRequestDiscardsOldResult",
    ),
    Mutation(
        name="failed consumer builds retry without a bound",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="if failedGeneration == before",
        new="if failedGeneration == before && false",
        test="ProjectRunnerBrokerTests/testRepeatedFailedBuildsAreBoundedUntilInputChanges",
    ),
    Mutation(
        name="external runner replacement is ignored",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="if includeExecutable {",
        new="if false {",
        test="ProjectRunnerBrokerTests/testExternalBuildProductReplacementRestartsChild",
    ),
    Mutation(
        name="consumer source scans ignore the byte limit",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="bytesRead <= maximumBytes,",
        new="true,",
        test="ProjectRunnerBrokerTests/testSourceScanBudgetsRefuseExcessDataAndTime",
    ),
    Mutation(
        name="consumer resource contents are not fingerprinted",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old="hash.update(data: chunk)",
        new="hash.update(data: Data())",
        test="ProjectRunnerBrokerTests/testGeneratedTreesAreIgnoredButResourceEditsInvalidateGeneration",
    ),
    Mutation(
        name="generated Swift scratch builds consume source scan budget",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old='file.lastPathComponent.hasPrefix(".build-")',
        new='file.lastPathComponent.hasPrefix(".never-generated-")',
        test="ProjectRunnerBrokerTests/testScratchBuildsAndIndexesCannotExhaustSourceBudget",
    ),
    Mutation(
        name="generated source indexes consume source scan budget",
        path="Sources/VerdictUICLICore/ProjectRunnerBroker.swift",
        old='"coverage", ".vexp",',
        new='"coverage", ".never-index",',
        test="ProjectRunnerBrokerTests/testScratchBuildsAndIndexesCannotExhaustSourceBudget",
    ),
]
