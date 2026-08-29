"""Mutation rows for the Python harness under scripts/.

Part of the `mutation_catalog` package; see its `__init__` for why the
catalog is split and for the rule about quoting text from these files.
"""

from mutation_catalog_types import Mutation, Runner  # noqa: F401

MUTATIONS: list[Mutation] = [
    Mutation(
        name="the demo stage re-enters SwiftPM instead of running the built executable",
        path="scripts/verdictui-pm.py",
        old="[str(demo)]",
        new='["swift", "run", str(demo)]',
        test=(
            "Tests/test_verdictui_pm.py::TestStageWrappers::"
            "test_stage_demo_runs_the_built_executable_not_swiftpm"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The mutation is the ORIGINAL defect (CIS-9EC205DF), not merely a
        # different spelling: `setattr` -> attribute syntax WITH a type-ignore is
        # also pyright-clean, so that variant is correctly UNNOTICED -- both
        # honestly satisfy the test's claim. Dropping the suppression entirely is
        # what the guard exists to catch, so that is what this row mutates to.
        name="the runtime attribute stash stops being type-checkable",
        path="scripts/verdictui-pm.py",
        old="    setattr(swift_runner, _RAW_KILL_ATTR, raw_kill)",
        new="    swift_runner._verdictui_raw_kill_zombie_swift_processes = raw_kill",
        test=("Tests/test_verdictui_pm.py::TestStageBuild::test_the_pm_script_is_pyright_clean"),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # A stale expansion in ANY consuming target makes a runtime witness
        # execute the previous plugin build, so the harness prints UNNOTICED for
        # a guard that works (`no.md` #23/#26/#28) — the expensive direction,
        # because it reads as a coverage gap and invites rewriting correct code.
        # Truncating the loop keeps every binding live (`no.md` #31) and leaves
        # VerdictUIMacroRuntimeTests stale forever with every signal green.
        name="the macro re-stamp covers only the first declared directory",
        path="scripts/mutation-check.py",
        old="    for directory in MACRO_CONSUMING_TEST_DIRS:",
        new="    for directory in MACRO_CONSUMING_TEST_DIRS[:1]:",
        test=(
            "Tests/test_mutation_check.py::TestMacroExpansionFreshness::"
            "test_every_declared_macro_dir_is_restamped_not_just_the_first"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Resolving against the process cwd instead of REPO makes the helper
        # touch NOTHING in a detached worktree while returning normally — a
        # silent no-op that reports success and reinstates the exact stale
        # expansion it exists to prevent. `Path(directory)` still compiles and
        # still iterates, so the mutation breaks behaviour rather than the build.
        name="the macro re-stamp resolves against the cwd instead of REPO",
        path="scripts/mutation-check.py",
        old="        root = resolve_in_repo(directory)",
        new="        root = Path(directory)",
        test=(
            "Tests/test_mutation_check.py::TestMacroExpansionFreshness::"
            "test_the_stamp_resolves_against_repo_not_the_process_cwd"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The blind spot measured 2026-08-21: `ceo.py --watch 30` drove a full
        # SagaMail suite to load average 241.37 while this tree's timing stages
        # ran, and the pattern list saw nothing because both other entries name
        # THIS project's processes. One commit read 120.23ms contended and
        # 9.63ms exclusive — a 12x swing that filed three P1s naming code that
        # was never slow. Mutated to a pattern that cannot match any real
        # process, so the tuple stays well-formed and every binding stays live
        # (no.md #31) while the guard loses exactly the contender it was added
        # for.
        name="the contention probe stops seeing a sibling project's sweep",
        path="scripts/verdictui-pm.py",
        old='    "ceo.py --watch",',
        new='    "ceo.py --a-pattern-no-process-can-match",',
        test=(
            "Tests/test_verdictui_pm_artifact_stages.py::TestTreeIsContended::"
            "test_a_sibling_projects_pm_saturating_the_machine_is_contention"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Dropping the self-exclusion makes the PM report its OWN pid as a
        # contender, so the guard is permanently True — worse than the blind
        # spot it replaced, because a guard that always fires gets discounted
        # on every future finding (no.md #72). Keeps every binding live.
        name="the contention probe stops excluding the PM's own pid",
        path="scripts/verdictui-pm.py",
        old="if pid.strip() != str(os.getpid())",
        new="if pid.strip() or True",
        test=(
            "Tests/test_verdictui_pm_artifact_stages.py::TestTreeIsContended::"
            "test_the_pm_does_not_report_ITSELF_as_contention"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Without the guard the PM tells the reader to `install -m 755` over a
        # tap symlink to a read-only Cellar file, clobbering the tap and
        # desyncing its INSTALL_RECEIPT.json. A destructive SUGGESTION is a
        # defect even though the PM never runs it. Keeps every binding live.
        name="the reinstall hint stops refusing package-managed copies",
        path="scripts/verdictui-pm.py",
        old='if "/Cellar/" in str(Path(copy).resolve()) or copy.startswith("/opt/homebrew/"):',
        new='if copy.startswith("/nonexistent-prefix/"):',
        test=(
            "Tests/test_verdictui_pm_artifact_stages.py::TestReinstallHint::"
            "test_a_homebrew_symlink_is_refused_and_says_why"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Scanning the WHOLE detail instead of its leading clause reinstates the
        # inverse false reading: a stage that RAN and named a skipped SUB-check
        # mid-sentence gets marked unverified, hiding executing work while
        # claiming to reveal hidden work. Keeps every binding live (no.md #31).
        name="the skip classifier scans the whole detail instead of its leading clause",
        path="scripts/verdictui-pm.py",
        old='head = lowered.split("|", 1)[0].strip()',
        new="head = lowered",
        test=(
            "Tests/test_verdictui_pm_artifact_stages.py::TestSkippedStagesAreVisibleAsSkips::"
            "test_a_stage_that_RAN_but_skipped_a_SUB_check_is_not_a_skip"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The mtime-vs-commit ordering IS the detector: without it an ordinary
        # dirty file and a stale overwrite are indistinguishable, which is the
        # exact confusion the script exists to resolve. Comparing against a
        # value no real timestamp can beat keeps every binding live (no.md #31)
        # while removing the discrimination.
        name="the stale-buffer detector stops comparing mtime against the commit time",
        path="scripts/stale-buffer-check.py",
        old="        if mtime < committed:",
        new="        if mtime < 0:",
        test=(
            "Tests/test_stale_buffer_check.py::TestStaleOverwrites::"
            "test_a_stale_buffer_is_caught_with_both_timestamps"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The guard's whole value is telling a CONTENDED red apart from a real
        # one. Reporting False unconditionally keeps every binding live and
        # still type-checks; it simply reinstates the state that produced ten
        # false P1s in a day. no.md #31: break behaviour, never a binding.
        name="the contention guard stops distinguishing a busy tree from a broken one",
        path="scripts/verdictui-pm.py",
        old="        if others:\n            load1, cpus = _current_load()",
        new="        if others and False:\n            load1, cpus = _current_load()",
        test=(
            "Tests/test_verdictui_pm_artifact_stages.py::TestTreeIsContended::"
            "test_a_running_fleet_sweep_is_contention"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # no.md #31: keep every binding live. Returning only the resolver's
        # first hit still compiles and still type-checks; it simply reinstates
        # the blind spot -- the gate sees the developer's own build (in parity
        # by construction) and never the packaged copy that actually ships.
        name="the parity gate goes back to checking only the first copy on PATH",
        path="scripts/verdictui-pm.py",
        old="    seen: list[str] = [first]",
        new="    return [first]\n    seen: list[str] = [first]",
        test=(
            "Tests/test_verdictui_pm.py::TestStageInstalledParity::"
            "test_the_resolver_helper_returns_every_path_copy_not_just_the_first"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The blank line is FALSY, so the original predicate walked past it into
        # the "See 'verdictui help ...'" footer and collected "See" as a
        # subcommand. Restoring that reinstates the phantom.
        name="the help-footer terminator stops closing the SUBCOMMANDS block",
        path="scripts/verdictui-pm.py",
        old='if not line.startswith(" ") or not line.strip():',
        new='if line and not line.startswith(" "):',
        test=(
            "Tests/test_verdictui_pm.py::TestStageInstalledParity::"
            "test_the_trailing_help_footer_is_not_parsed_as_a_subcommand"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="the demo stage accepts an empty verdict array",
        path="scripts/verdictui-pm.py",
        old="if not isinstance(verdicts, list) or not verdicts:",
        new="if not isinstance(verdicts, list):",
        test=(
            "Tests/test_verdictui_pm.py::TestStageWrappers::"
            "test_stage_demo_fails_on_an_empty_verdict_array"
        ),
        runner=Runner.PYTEST,
    ),
    # The bench stage gates the MEDIAN, not the tail. Three rows, because the
    # decision has three independently-breakable halves and one row would let
    # the other two rot silently.
    Mutation(
        # The regression direction. Without this the stage could stop failing
        # altogether and the "does not fail on a contended tail" row below
        # would still pass — a gate that never fails satisfies it perfectly.
        name="the bench stage stops failing on a regressed median",
        path="scripts/verdictui-pm.py",
        old="if p50 >= SLO1_P50_BUDGET_MS:",
        new="if False:",
        test=(
            "Tests/test_verdictui_bench.py::TestStageRuntimeBench::"
            "test_a_regressed_median_fails_even_with_a_healthy_tail"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The false-positive direction — the actual 2026-08-07 defect restored
        # verbatim. This is the row that would have caught it: the stage asserted
        # a statistic that moves with machine load, so it failed at p95 105.51 ms
        # on a healthy p50 of 49.09 ms.
        name="the bench stage goes back to gating the contended tail",
        path="scripts/verdictui-pm.py",
        old="if p50 >= SLO1_P50_BUDGET_MS:",
        new="if tail is not None and float(tail.group(1)) >= SLO1_P95_BUDGET_MS:",
        test=(
            "Tests/test_verdictui_bench.py::TestStageRuntimeBench::"
            "test_a_contended_tail_does_not_fail_the_stage"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The two thresholds live in different languages and neither file can
        # see the other, so their agreement is only real while something
        # compares them. Moving one here must fail.
        name="the PM's p50 budget drifts from the Swift test's",
        path="scripts/verdictui-pm.py",
        old="SLO1_P50_BUDGET_MS = 70.0",
        new="SLO1_P50_BUDGET_MS = 85.0",
        test=(
            "Tests/test_verdictui_bench.py::TestStageRuntimeBench::"
            "test_the_gated_budget_agrees_with_the_swift_test"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="an empty mutation catalog reports success",
        path="scripts/mutation-check.py",
        old='        print("the mutation catalog is empty — nothing was verified")\n        return 1\n    problems = [',
        new="        pass\n    problems = [",
        test=(
            "Tests/test_mutation_check.py::TestVerifyTargets::"
            "test_an_empty_catalog_fails_rather_than_reporting_nothing_wrong"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="a broken build is blamed on a renamed test",
        path="scripts/mutation-check.py",
        old='        if "error:" in combined:\n            return "unmutated source does not build',
        new='        if False:\n            return "unmutated source does not build',
        test=(
            "Tests/test_mutation_check.py::TestBaselineProblem::"
            "test_a_tree_that_does_not_build_says_so_instead_of_blaming_the_name"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The PM-side half of the same lane. Every marker test asserts a marker
        # turns record-only ON, and `if True` satisfies all of them -- measured
        # 2026-08-09 at 199/199 passing with the guard fully defeated. That is
        # the expensive direction: record-only everywhere means the p50 budget
        # is enforced NOWHERE while the suite reads green, so the gate stops
        # being a gate without one test noticing (no.md #12, #15).
        #
        # Unlike the Swift row above, `if True` IS the right mutation here:
        # the predicate returns a value rather than guarding an assertion, so
        # a healthy tree can witness it through the negative control.
        name="every host is treated as timing-constrained, so p50 gates nothing",
        path="scripts/verdictui-pm.py",
        old="    if any(name in os.environ for name in CONSTRAINED_TIMING_ENV_MARKERS):",
        new="    if True:",
        test=(
            "Tests/test_verdictui_pm.py::TestSkipSentinel"
            "::test_unmarked_writable_host_still_asserts_its_timings"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Removes the mid-run clean-tree check, restoring the state where an
        # edit landing during a ~30 minute sweep makes every later case measure
        # a tree nobody intended and report SETUP FAILED as if a guard broke.
        name="a tree going dirty mid-sweep is no longer noticed",
        path="scripts/mutation-check.py",
        old='        if not git_is_clean():\n            print("  ABORTED: the working tree changed mid-run")',
        new='        if False:\n            print("  ABORTED: the working tree changed mid-run")',
        test="Tests/test_mutation_check.py::TestMidRunTreeGuard::test_main_aborts_when_the_tree_goes_dirty_mid_run",
        runner=Runner.PYTEST,
    ),
    Mutation(
        # stage_lint stops reporting any failure. Every pre-existing lint test
        # checked the tool-missing path, the clean-repo path, or grepped the
        # PM's own source for the argv it builds — none ran the stage against
        # BROKEN code, so this mutation passed the whole suite.
        name="stage_lint stops reporting lint and format failures",
        path="scripts/verdictui-pm.py",
        old="            if r.returncode != 0:\n                detail = (r.stdout.strip() or r.stderr.strip() or NO_OUTPUT)[:400]",
        new="            if False:\n                detail = (r.stdout.strip() or r.stderr.strip() or NO_OUTPUT)[:400]",
        test="Tests/test_verdictui_pm.py::TestStageWrappers::test_stage_lint_reports_a_format_failure_distinctly",
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The guard `no.md` #16 recorded as UNROWABLE, now rowable — which is the
        # point of splitting the catalog out of the harness.
        #
        # `-B` makes the pytest witness COMPILE the source the harness just
        # wrote instead of reading `__pycache__`. Without it, two rows touching
        # one file inside the same second make the witness judge the PREVIOUS
        # row's compile (CPython validates its cache on mtime plus size at
        # one-second granularity), so a working guard reports UNNOTICED — which
        # reads as "untested" and invites rewriting correct code. Measured
        # 2026-08-07: exactly one of six went UNNOTICED in a full sweep and
        # NOTICED when re-run alone.
        #
        # While the catalog lived inside `mutation-check.py` this row could not
        # exist: its own `old=` string was a second occurrence of the argv, so
        # `--verify-targets` refused it. Two files that do not quote each other
        # is what makes it expressible.
        name="the pytest witness may be served a stale __pycache__ compile",
        path="scripts/mutation-check.py",
        old='return run([sys.executable, "-B", "-m", "pytest"',
        new='return run([sys.executable, "-m", "pytest"',
        test=(
            "Tests/test_mutation_check.py::TestPytestRunner"
            "::test_a_mutated_module_is_not_served_from_stale_bytecode"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The Swift witness stops judging the plugin the harness just wrote.
        # SwiftPM rebuilds a `.macro` plugin but does NOT re-expand macros in a
        # consuming target whose own sources are unchanged, so a RUNTIME witness
        # executes the PREVIOUS expansion and passes against a broken plugin
        # (`no.md` #23/#26). That defeats this harness in the expensive
        # direction: a working guard reports UNNOTICED, which reads as
        # "uncovered" and invites rewriting correct code.
        #
        # Measured 2026-08-11: the composition row went UNNOTICED in a full
        # sweep and NOTICED (exit 1, 1 test executed, failing on
        # `vacuous-verdict`) when the same mutation was applied by hand with the
        # consuming test files touched first. The row's own note already claimed
        # a hand-verification the harness could not reproduce, because the hand
        # check followed the touch discipline and the harness did not.
        name="the swift witness is served a stale macro expansion",
        path="scripts/mutation-check.py",
        old="    refresh_macro_expansions()\n",
        new="",
        test=(
            "Tests/test_mutation_check.py::TestMacroExpansionFreshness::"
            "test_the_swift_runner_restamps_macro_consuming_sources"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The harness stops noticing that something else wrote to the file while
        # its witness ran, and classifies the result anyway. Measured with the
        # guard removed: it prints NOTICED for a row whose subject had been
        # rewritten mid-run — a confident verdict about a tree nobody intended,
        # which is exactly how a working guard gets reported as untested
        # (`no.md` #14, CTS-8795E0FE).
        name="a mid-run write to the mutated file no longer aborts the row",
        path="scripts/mutation-check.py",
        old="        if sha256(path) != expected_mutated:",
        new="        if False:",
        test=(
            "Tests/test_mutation_check.py::TestPerRowTreeOwnership"
            "::test_a_write_during_the_witness_run_aborts_rather_than_scoring"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The detector stops comparing TIME and reports every modified file.
        # That is the failure mode the control exists for: identical to
        # `git status`, useless as a signal, and noisy enough that the real
        # stale-buffer case would be ignored among the false ones.
        name="the stale-buffer detector reports any dirty file",
        path="scripts/stale-buffer-check.py",
        old="        if mtime < committed:",
        new="        if True:",
        test=(
            "Tests/test_stale_buffer_check.py::TestStaleOverwrites"
            "::test_ordinary_work_in_progress_is_NOT_reported"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # SLO 3's gate stops gating: the median is compared against the PRODUCT
        # target (100 ms) instead of the enforced budget (40 ms), so a round trip
        # 2.5x slower than today's still passes while the stage keeps printing a
        # confident figure. A budget quietly widened to the published ceiling is
        # the silencer shape SE Principle 11 forbids, and it is invisible in a
        # log -- every line still reads "SLO 3 p50 ... < ...".
        name="the MCP latency gate compares against the product target, not its budget",
        path="scripts/verdictui-pm.py",
        old="        if p50 >= SLO3_MCP_P50_BUDGET_MS:",
        new="        if p50 >= SLO3_MCP_P95_BUDGET_MS:",
        test="Tests/test_verdictui_bench.py::TestStageMCPLatency"
        "::test_the_gated_figure_is_the_median_not_the_tail",
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The shared SLO parse stops failing closed on a stale filter. A
        # `swift test --filter` that matches nothing exits 0 having executed no
        # tests, so without this check a renamed test class turns BOTH SLO gates
        # green forever -- and green is exactly what a silently-unmeasured
        # benchmark looks like.
        name="the shared SLO parse accepts a run that executed no tests",
        path="scripts/verdictui-pm.py",
        old='        return {"detail": f"{marker}: no executed tests reported -- the filter is stale"}',
        new='        _ = f"{marker}: no executed tests reported -- the filter is stale"',
        test="Tests/test_verdictui_bench.py::TestSharedSLOParse"
        "::test_a_filter_that_matched_nothing_is_a_failure_not_a_pass",
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The wire gate stops excluding the verb documented as NOT SERVED,
        # so stage_transport_smoke would REQUIRE baseline_accept to answer
        # over the wire -- inverting the SD4 guarantee the same stage checks
        # two assertions later. The failure is silent in the dangerous
        # direction: the gate still passes on a catalog that serves the
        # destructive verb, and fails on the correct catalog that does not.
        name="the wire gate stops excluding the deliberately unserved verb",
        path="scripts/verdictui-pm.py",
        old='        if not line.startswith("###") or "NOT SERVED" in line:',
        new='        if not line.startswith("###"):',
        test=(
            "Tests/test_verdictui_pm_artifact_stages.py::TestDocumentedMCPTools::"
            "test_the_deliberately_unserved_verb_is_excluded"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The contract parser stops distinguishing a tool heading from a
        # SUB-heading, so option names documented under #### become verbs
        # the wire gate demands answer -- failing the stage against a
        # correct catalog. The obvious guard (startswith("###")) does NOT
        # catch this: #### satisfies it too. What rejects a sub-heading is
        # dropping exactly three characters and requiring a backtick, so
        # THAT is the line this row breaks. Measured: loosening the heading
        # test alone left the witness PASSING (no.md #12).
        name="the contract parser stops rejecting deeper heading levels",
        path="scripts/verdictui-pm.py",
        old="        marker = line[3:].lstrip()",
        new='        marker = line.lstrip("#").lstrip()',
        test=(
            "Tests/test_verdictui_pm_artifact_stages.py::TestDocumentedMCPTools::"
            "test_a_deeper_heading_level_is_not_a_tool"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Restores the state where a SKIPPED witness is scored as a passing
        # one. A skipped XCTest prints `passed`, exits 0, and emits no skip
        # marker at any verbosity, so `classify` reads ran=1 + exit 0 and
        # reports `UNNOTICED — the test passed with the guard broken`. That
        # sentence is false in the expensive direction: it accuses a working
        # guard of being untested, which is what invites rewriting correct
        # code. Measured 2026-08-15 — exactly this produced the only UNNOTICED
        # in a 121-row sweep, against an AX guard that was entirely fine.
        # `if False` keeps every binding live and compiles (`no.md` #31).
        name="a witness that can skip is scored as if it had run",
        path="scripts/mutation-check.py",
        old="    if mutation.skips_when:",
        new="    if False:",
        test=(
            "Tests/test_mutation_check.py::TestSkippableWitness"
            "::test_a_row_declaring_it_can_skip_is_not_scored_as_a_witness"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # VERDICTUI_RECORD_TIMING_ONLY is the EXPLICIT HUMAN OVERRIDE, not a
        # clock marker: it is the one input that suppresses
        # canEvaluateElapsedInvariants. Wrapping the FULL suite in it therefore
        # runs every test with the overshoot invariant switched off -- the gate
        # that stopped gating, which reads exactly like a gate that passed
        # (no.md #58). stage_runtime_bench keeps the wrapper, correctly: that
        # stage measures absolute budgets, which is what the override is for.
        # Hand-verified 2026-08-15 -- exit 1, byte-identical restore.
        name="the full suite runs under the record-only override again",
        path="scripts/verdictui-pm.py",
        old="        return _run_streamed_swift_test(\n            timeout=TIMEOUT_SWIFT_TEST,",
        new=(
            "        with _swift_timing_environment():\n"
            "            return _run_streamed_swift_test(\n"
            "            timeout=TIMEOUT_SWIFT_TEST,"
        ),
        test=(
            "Tests/test_verdictui_pm.py::TestSkipSentinel"
            "::test_stage_test_does_not_force_the_explicit_record_only_override"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # A SKIP is "could not observe" -- neither pass nor fail. The summary
        # regex discarded the count in a non-capturing group, so a run that
        # stopped observing anything printed exactly like one that observed
        # everything: measured 2026-08-15, the five AX witness tests skipped on
        # a degraded window server while the PM reported Grade A, leaving the
        # cross-validation channel unverified with no signal anywhere. Reported,
        # never gated -- skipping rather than accusing is correct for an
        # environment the suite cannot see (no.md #15), so this row guards the
        # AUDIBILITY of the silence, not a new failure mode. Assigning "" keeps
        # the binding live and compiles (no.md #31).
        name="a skipped test is silently counted as verified again",
        path="scripts/verdictui-pm.py",
        old='skipped_note = f" ({exec_skipped} SKIPPED — unverified)" if exec_skipped else ""',
        new='skipped_note = ""',
        test=(
            "Tests/test_verdictui_pm.py::TestKilledRunnerIsInconclusive"
            "::test_a_skipped_test_is_reported_rather_than_silently_counted_as_verified"
        ),
        runner=Runner.PYTEST,
    ),
]
