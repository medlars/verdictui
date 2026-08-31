"""Mutation rows for everything else — Tests/, Package.swift, docs and CLAUDE.md.

Part of the `mutation_catalog` package; see its `__init__` for why the
catalog is split and for the rule about quoting text from these files.
"""

from mutation_catalog_types import Mutation, Runner  # noqa: F401

MUTATIONS: list[Mutation] = [
    # CTS-9E32C9AB -- the degenerate windows list. Four sessions read the
    # geometry framing this guard's absence produced and recorded the work
    # blocked on machine load, then on a fresh login session. Both mutations are
    # SILENT without a witness: the suite still passes, and the only visible
    # change is which sentence the reader is sent to act on.
    Mutation(
        name="the application element is accepted as a window again",
        path="Sources/VerdictUIWitness/AXReader.swift",
        old="        return role != (kAXApplicationRole as String)",
        new="        return true",
        test=(
            "VerdictUIWitnessTests.AXReaderTests/"
            "testTheApplicationElementIsNotAcceptedAsAWindow"
        ),
        runner=Runner.SWIFT,
    ),
    Mutation(
        # The opposite failure, and the one a careless fix makes: a predicate
        # that rejects everything satisfies "the app element is not a window"
        # perfectly while making every real window unreadable -- including
        # Finder's desktop, which publishes as AXScrollArea rather than AXWindow.
        name="the window predicate rejects every role",
        path="Sources/VerdictUIWitness/AXReader.swift",
        old="        return role != (kAXApplicationRole as String)",
        new="        return false",
        test="VerdictUIWitnessTests.AXReaderTests/testOrdinaryWindowRolesAreStillAccepted",
        runner=Runner.SWIFT,
    ),
    Mutation(
        # Mutates the MANIFEST, because the floor is the thing consumers collide
        # with. A .v14 floor makes SwiftPM refuse every consumer pinned lower and
        # blame the PRODUCT rather than the one API responsible, so nothing in
        # this repo would report it -- LaunchGate (.v13) was locked out entirely.
        name="the package floor rises above the lowest fleet target again",
        path="Package.swift",
        old="        .macOS(.v13)",
        new="        .macOS(.v14)",
        test=(
            "Tests/test_verdictui_pm.py::TestDeploymentFloor::"
            "test_the_package_floor_stays_at_the_lowest_fleet_target"
        ),
        runner=Runner.PYTEST,
    ),
    # Wave 4 Task 1 — the macro target's isolation. All three of these are
    # manifest-shaped: they change no behaviour and break no Swift test, so
    # `swift test` is blind to every one of them. That is precisely why they
    # need witnesses; the cost they impose (SwiftSyntax on every consumer's
    # build) is invisible to a suite that only measures what the code does.
    Mutation(
        name="a shipping target is allowed to depend on SwiftSyntax",
        path="Package.swift",
        old='.target(name: "VerdictUIKernel", swiftSettings: strictSettings)',
        new=(
            '.target(name: "VerdictUIKernel", dependencies: '
            '[.product(name: "SwiftSyntax", package: "swift-syntax")], '
            "swiftSettings: strictSettings)"
        ),
        test=(
            "Tests/test_macro_isolation.py::TestMacroTargetIsolation::"
            "test_the_shipping_targets_never_reach_swiftsyntax"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="the macro plugin is demoted to a regular target",
        path="Package.swift",
        old='        .macro(\n            name: "VerdictUIMacros",',
        new='        .target(\n            name: "VerdictUIMacros",',
        test=(
            "Tests/test_macro_isolation.py::TestMacroTargetIsolation::"
            "test_the_plugin_is_declared_as_a_macro_target"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="the SwiftSyntax pin is loosened from exact to a range",
        path="Package.swift",
        old='exact: "603.0.2"',
        new='from: "603.0.0"',
        test=(
            "Tests/test_macro_isolation.py::TestMacroTargetIsolation::"
            "test_swiftsyntax_is_pinned_exactly"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="CLAUDE.md's SSoT table points at a file that does not exist",
        path="CLAUDE.md",
        old="Sources/VerdictUIProbe/OracleHost.swift",
        new="Sources/VerdictUIProbe/OracleHostRenamed.swift",
        test=("Tests/test_claude_md_ssot.py::TestClaudeMdSSoT::test_every_ssot_location_exists"),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="CLAUDE.md's SSoT table names a symbol that moved",
        path="CLAUDE.md",
        old="`VerdictScenario`",
        new="`VerdictScenarioProtocol`",
        test=(
            "Tests/test_claude_md_ssot.py::TestClaudeMdSSoT::"
            "test_every_ssot_symbol_lives_where_the_table_says"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Retargeting a row rather than deleting one: this leaves every row
        # pointing at a real file, so only the completeness direction can catch it.
        name="a source file loses its FILE_REGISTRY row",
        path="docs/FILE_REGISTRY.md",
        old="| `scripts/dev.sh`",
        new="| `scripts/floor-check.py`",
        test=(
            "Tests/test_file_registry.py::TestFileRegistry::"
            "test_every_authored_source_file_has_an_active_row"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The one guard here whose subject is a policy constant rather than a
        # file: it fails when a tracked file's type is in neither classification
        # set, and no edit to a *document* can produce that. Dropping `.swift`
        # from the source set is the honest equivalent of adding an unclassified
        # file type, and proves the canary reads the tree instead of itself.
        name="a file type drops out of both classification sets",
        path="Tests/test_file_registry.py",
        old='".swift", ',
        new="",
        test=(
            "Tests/test_file_registry.py::TestFileRegistry::test_every_tracked_suffix_is_classified"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Anchored on the widest Purpose cell, the one row the markdown formatter
        # leaves unpadded, so this target does not depend on column alignment. If
        # a longer purpose is ever written, --verify-targets reports this STALE.
        name="a source file's registry row is flipped out of Active",
        path="docs/FILE_REGISTRY.md",
        old="tree delivery | Active |",
        new="tree delivery | Removed |",
        test=(
            "Tests/test_file_registry.py::TestFileRegistry::"
            "test_every_authored_source_file_has_an_active_row"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="a FILE_REGISTRY row is left behind by a rename",
        path="docs/FILE_REGISTRY.md",
        old="| `scripts/floor-check.py`",
        new="| `scripts/floor-check-renamed.py`",
        test=(
            "Tests/test_file_registry.py::TestFileRegistry::"
            "test_every_active_row_points_at_a_path_that_exists"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The p50 gate is asserted on developer hardware and RECORDED on a
        # shared runner (five CI medians on unchanged code spanned 74-120 ms
        # against a 70 ms budget). INVERTING the lane predicate is the
        # single-edit break that a healthy tree can witness: the local run then
        # takes the record-only branch and stops asserting, while a run with
        # CI set starts asserting the very figure it must not.
        #
        # Deliberately NOT `if true {`. That reads like the obvious mutation
        # and is unfalsifiable on healthy code — the assertion simply never
        # runs and everything passes, so the row would score UNNOTICED while
        # the guard is fine (no.md #12: an assertion that both the correct and
        # the broken implementation satisfy is not a weak test, it is not a
        # test). The inversion is caught by a different assertion in the same
        # test: `stage_runtime_bench` and the local lane both expect the
        # SLO1-PERFORM-P50 recorded line to be ABSENT off-CI.
        name="the SLO 1 lane predicate is inverted, gating CI and exempting dev",
        path="Tests/VerdictUIProbeTests/HarnessPerformanceTests.swift",
        old="private static var assertsP50Locally: Bool { !isSharedCIRunner }",
        new="private static var assertsP50Locally: Bool { isSharedCIRunner }",
        test="HarnessPerformanceTests/testTheP50GateIsAssertedOnDeveloperHardware",
    ),
    Mutation(
        # Restores the raw errorCount assertion the skip guard replaced. The
        # guard exists so a checkout that is NOT a sibling of shared-libs
        # (a detached worktree under /tmp) skips with a named reason instead
        # of reporting reportMissingImports as a type error in the code -- a
        # check failing for a reason other than the one it exists for. The
        # witness asserts the guard is present and reachable rather than
        # relying on a diagnostic the main tree does not produce, since in a
        # sibling checkout there are no missing imports to filter at all.
        name="the pyright check asserts the raw error count with no checkout guard",
        path="Tests/test_verdictui_pm.py",
        old="        report = json.loads(proc.stdout)",
        new='        report = {"summary": {"errorCount": 1}, "generalDiagnostics": []}',
        test=("Tests/test_verdictui_pm.py::TestStageBuild::test_the_pm_script_is_pyright_clean"),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Restores the state where a VACUOUS AX read scores as a passing one.
        # Both bound assertions in that test are `<=`, so they hold for a
        # ONE-NODE tree, and XCTest emits no skip marker (no.md #62) -- so a
        # read that observed nothing posts the best numbers the suite has ever
        # seen. Substituting `<=` keeps every binding live and compiles
        # (no.md #31) while making the floor satisfiable by any tree at all.
        #
        # The floor is a NODE COUNT rather than a duration, and that was the
        # correction this row exists to protect: the first version asserted
        # elapsed > 0.1s against a documented "~2s healthy read", and FAILED A
        # WORKING READER -- five consecutive genuine Finder reads measured
        # 0.043-0.090s, and one run of the same code measured 3.376s under
        # load, a ~78x spread. Duration measures the target app's window state
        # and the machine; only the node count measures whether the walk
        # observed anything.
        name="a vacuous AX read passes the tree-was-actually-read floor",
        path="Tests/VerdictUIWitnessTests/ThirdPartyAuditTests.swift",
        old="        XCTAssertGreaterThan(\n            tree.flattened().count, 1,",
        new="        XCTAssertLessThanOrEqual(\n            tree.flattened().count, Int.max,",
        test="ThirdPartyAuditTests/testTheReaderIsBoundedAgainstAHostileTree",
        skips_when=(
            "the host has no window server, lacks Accessibility permission, or no candidate "
            "third-party application publishes a readable window at that moment"
        ),
    ),
    Mutation(
        # The CONSUMER half of the row above. Splitting the predicate fixes
        # nothing if the site that READS it still names the clock lane, and the
        # two failures are indistinguishable from outside: both leave the
        # overshoot guard inert on a read-only-cache host while the suite reads
        # green. Hand-verified 2026-08-15 -- exit 1 naming the elapsed-invariant
        # assertion, byte-identical restore.
        name="the overshoot lane in HarnessTests reads the clock predicate",
        path="Tests/VerdictUIProbeTests/HarnessTests.swift",
        old="        !ConstrainedTimingEnvironment.canEvaluateElapsedInvariants",
        new="        ConstrainedTimingEnvironment.isActive",
        test=(
            "Tests/test_verdictui_bench.py::TestStageRuntimeBench"
            "::test_timeout_fixture_recording_is_not_the_elapsed_invariant_lane"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The hostile fixture must keep MOVING for as long as settle samples it,
        # or "it timed out" says nothing about quiescence and the test passes for
        # the opposite reason (no.md #47). Freezing the drive reproduces the CI
        # signature exactly -- settled(after: ~0.035s), which is 2 checks x 5 ms
        # plus the 30 ms quiet floor -- so this row guards the assertion that
        # separates "the screen was moving and settle lied" from "the screen was
        # static and settle was right". Assigning the model to _ keeps the
        # closure's capture live and compiles (no.md #31).
        name="the oscillating fixture stops advancing during settle",
        path="Tests/VerdictUIProbeTests/SettleTests.swift",
        old="            model.tick += 1\n        }\n        CFRunLoopAddObserver",
        new="            _ = model\n        }\n        CFRunLoopAddObserver",
        test="SettleTests/testOscillatingLayoutTimesOutWithDeltaEvidence",
    ),
]
