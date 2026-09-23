"""Workbench trust boundary and daemon resource-limit witnesses."""

from mutation_catalog_types import Mutation, Runner

MUTATIONS: list[Mutation] = [
    Mutation(
        name="installed parity mistakes wrapped descriptions for commands",
        path="scripts/verdictui_pm_smoke.py",
        old='                    if line.startswith("   "):\n                        continue',
        new="                    # continuation filter omitted under mutation",
        test="Tests/test_verdictui_pm.py::TestStageInstalledParity::test_wrapped_descriptions_are_not_subcommands",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="PM consumer gate omits persistent rebuild recovery",
        path="scripts/verdictui_pm_smoke.py",
        old='            ("--reload", "consumer reload PASS: same MCP/daemon PID"),',
        new="            # persistent recovery omitted under mutation",
        test="Tests/test_product_pm_stages.py::test_consumer_gate_requires_persistent_rebuild_recovery",
        runner=Runner.PYTEST,
    ),
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

MUTATIONS += [
    Mutation(
        name="workbench smoke accepts empty browser measurements",
        path="scripts/workbench-smoke.py",
        old="complete and measured and not self.failures",
        new="complete and not self.failures",
        test="Tests/test_workbench_smoke.py::test_both_browsers_must_run_assertions_not_just_start",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="workbench smoke accepts partial browser flows",
        path="scripts/workbench-smoke.py",
        old="complete and measured and not self.failures",
        new="measured and not self.failures",
        test="Tests/test_workbench_smoke.py::test_partial_browser_flow_is_not_complete_even_with_measured_assertions",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="workbench smoke ignores a measured failure",
        path="scripts/workbench-smoke.py",
        old="complete and measured and not self.failures",
        new="complete and measured",
        test="Tests/test_workbench_smoke.py::test_a_failed_assertion_is_counted_once_and_preserves_passes",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="PM workbench accepts missing measurement summary",
        path="scripts/verdictui_pm_smoke.py",
        old="result.returncode == 0 and measured is not None",
        new="result.returncode == 0",
        test="Tests/test_product_pm_stages.py::test_workbench_stage_requires_complete_measured_flows",
        runner=Runner.PYTEST,
    ),
]
