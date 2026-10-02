"""Mutation rows for the Python harness under scripts/.

Part of the `mutation_catalog` package; see its `__init__` for why the
catalog is split and for the rule about quoting text from these files.
"""

from mutation_catalog_types import Mutation, Runner  # noqa: F401

MUTATIONS: list[Mutation] = [
    Mutation(
        name="Swift version guard loses Linux format support",
        path="Tests/test_swift_toolchain_pin.py",
        old=r"^(?:Apple )?Swift version ",
        new=r"^Apple Swift version ",
        test="Tests/test_swift_toolchain_pin.py::test_local_guard_accepts_linux_version_output",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Swift version guard ignores toolchain drift",
        path="Tests/test_swift_toolchain_pin.py",
        old="assert found.group(1) == _pin(), (",
        new="assert found.group(1) is not None, (",
        test="Tests/test_swift_toolchain_pin.py::test_local_guard_rejects_wrong_version",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Summary loses native SF Symbol skip accounting",
        path="scripts/verify-swift-test-output.py",
        old=r"(?:\S+\s+)?Test",
        new=r"(?:[↷◇✔✘○→-]\s+)?Test",
        test="Tests/test_swift_test_execution.py::test_real_swift_64_all_skipped_symbols",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Summary loses missing summary diagnosis",
        path="scripts/verify-swift-test-output.py",
        old="elif not xctest and not swift:",
        new="elif False:",
        test="Tests/test_swift_test_execution.py::test_unavailable_reason",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Summary loses zero count diagnosis",
        path="scripts/verify-swift-test-output.py",
        old="elif total == 0:",
        new="elif False:",
        test="Tests/test_swift_test_execution.py::test_unavailable_reason",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Summary loses invalid skips diagnosis",
        path="scripts/verify-swift-test-output.py",
        old="elif xc_skips > xc_total or swift_skips > swift_total:",
        new="elif False:",
        test="Tests/test_swift_test_execution.py::test_unavailable_reason",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="PM loses native build system",
        path="scripts/verdictui_pm_support.py",
        old='    "--build-system",\n    "native",\n',
        new="",
        test="Tests/test_swift_test_execution.py::test_pm_stage_native",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Mutation runner loses native build system",
        path="scripts/mutation-check.py",
        old='            "--build-system",\n            "native",\n',
        new="",
        test="Tests/test_swift_test_execution.py::test_mutation_native",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Developer build loses native build system",
        path="scripts/dev.sh",
        old="swift build --build-system native",
        new="swift build",
        test="Tests/test_swift_test_execution.py::test_dev_native",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Developer test loses native build system",
        path="scripts/dev.sh",
        old="swift test --build-system native",
        new="swift test",
        test="Tests/test_swift_test_execution.py::test_dev_native",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="CI test loses native build system",
        path=".github/workflows/ci.yml",
        old="swift test --build-system native",
        new="swift test",
        test="Tests/test_swift_test_execution.py::test_ci_executes_and_admits",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="CI build loses native build system",
        path=".github/workflows/ci.yml",
        old="swift build --build-system native",
        new="swift build",
        test="Tests/test_swift_test_execution.py::test_ci_executes_and_admits",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="CI discards actual test exit status",
        path=".github/workflows/ci.yml",
        old="|| status=$?",
        new="|| status=0",
        test="Tests/test_swift_test_execution.py::test_ci_executes_and_admits",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Summary ignores command failure",
        path="scripts/verify-swift-test-output.py",
        old="if exit_code != 0:",
        new="if False:",
        test="Tests/test_swift_test_execution.py::test_summary_admission",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Summary ignores reported test failures",
        path="scripts/verify-swift-test-output.py",
        old='elif failures or any(status == "failed" for _, status in swift):',
        new="elif False:",
        test="Tests/test_swift_test_execution.py::test_summary_admission",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Summary admits all skipped tests",
        path="scripts/verify-swift-test-output.py",
        old="elif observed <= 0:",
        new="elif False:",
        test="Tests/test_swift_test_execution.py::test_summary_admission",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Summary admits missing and zero execution",
        path="scripts/verify-swift-test-output.py",
        old='"passed": reason == "completed tests observed",',
        new='"passed": True,',
        test="Tests/test_swift_test_execution.py::test_summary_admission",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Summary ignores Swift Testing skips",
        path="scripts/verify-swift-test-output.py",
        old="swift_skips = len(_SKIP.findall(output))",
        new="swift_skips = 0",
        test="Tests/test_swift_test_execution.py::test_summary_admission",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Swift mutation filter validator ignores earlier alternatives",
        path="Tests/test_mutation_check.py",
        old='for alternative in expression.split("|"):',
        new='for alternative in expression.split("|")[-1:]:',
        test="Tests/test_mutation_check.py::TestClassify::test_every_filter_alternative_is_checked",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="OS wait exception admits a missing site",
        path="Tests/test_verdictui_bench.py",
        old="if count != 1:",
        new="if count > 1:",
        test="Tests/test_verdictui_bench.py::TestNoSleepsInHarnessSource::test_os_wait_exceptions_are_exact[missing]",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="UI sleep scanner silently disables detection",
        path="Tests/test_verdictui_bench.py",
        old="if relative != cls._CLOCK and cls._PATTERN.search(code) and not approved:",
        new="if False:",
        test="Tests/test_verdictui_bench.py::TestNoSleepsInHarnessSource::test_the_detector_actually_fires",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="OS wait exception loses exact file boundary",
        path="Tests/test_verdictui_bench.py",
        old="relative == cls._OWNER",
        new="True",
        test="Tests/test_verdictui_bench.py::TestNoSleepsInHarnessSource::test_os_wait_exceptions_are_exact[wrong-path]",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="OS wait exception admits changed interval",
        path="Tests/test_verdictui_bench.py",
        old="and code.strip() == cls._WAIT",
        new="and True",
        test="Tests/test_verdictui_bench.py::TestNoSleepsInHarnessSource::test_os_wait_exceptions_are_exact[wrong-interval]",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="OS wait exception loses unique occurrence guard",
        path="Tests/test_verdictui_bench.py",
        old="if count != 1:",
        new="if False:",
        test="Tests/test_verdictui_bench.py::TestNoSleepsInHarnessSource::test_os_wait_exceptions_are_exact[duplicate]",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="OS wait exception admits unknown extra marker",
        path="Tests/test_verdictui_bench.py",
        old="and marker in cls._MARKERS",
        new="and True",
        test="Tests/test_verdictui_bench.py::TestNoSleepsInHarnessSource::test_os_wait_exceptions_are_exact[unknown-extra]",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Virtual clock exception widens to any matching filename",
        path="Tests/test_verdictui_bench.py",
        old="relative != cls._CLOCK",
        new='path.name != "VerdictClock.swift"',
        test="Tests/test_verdictui_bench.py::TestNoSleepsInHarnessSource::test_the_detector_actually_fires",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="PM pytest discards the original failure and timeout output",
        path="scripts/verdictui_pm_smoke.py",
        old="        os.replace(temporary, path)",
        new="        os.unlink(temporary)",
        test="Tests/test_verdictui_failclosed.py::TestStagePytest::test_full_failure_and_timeout_output_is_retained",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="PM pytest reports green when failure evidence cannot be saved",
        path="scripts/verdictui_pm_smoke.py",
        old='"detail": f"pytest evidence could not be retained: {exc}"[:300],',
        new='"detail": "lost evidence", "passed": True,',
        test="Tests/test_verdictui_failclosed.py::TestStagePytest::test_storage_failure_cannot_report_green",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="PM cleanup treats a transient group probe permission error as absence",
        path="scripts/verdictui_pm_swift.py",
        old=(
            "            except PermissionError:\n"
            "                # Darwin can report EPERM while a signalled group exits. Only\n"
            "                # ESRCH proves absence; retry within the same bounded wait.\n"
            "                pass"
        ),
        new="            except PermissionError:\n                return",
        test=(
            "Tests/test_verdictui_pm.py::TestOwnedGroupDescendants"
            "::test_transient_probe_permission_error_is_not_group_absence"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="PM cleanup mistakes a reaped leader for a stopped process group",
        path="scripts/verdictui_pm_swift.py",
        old="            proc.poll()\n            try:\n                os.killpg(proc.pid, 0)",
        new=(
            "            if proc.poll() is not None:\n                return\n"
            "            try:\n                os.killpg(proc.pid, 0)"
        ),
        test=(
            "Tests/test_verdictui_pm.py::TestOwnedGroupDescendants"
            "::test_exited_leader_does_not_leave_term_resistant_descendant"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="PM cleanup never escalates the surviving owned group",
        path="scripts/verdictui_pm_swift.py",
        old="for sig in (signal.SIGTERM, signal.SIGKILL):",
        new="for sig in (signal.SIGTERM,):",
        test=(
            "Tests/test_verdictui_pm.py::TestOwnedGroupDescendants"
            "::test_exited_leader_does_not_leave_term_resistant_descendant"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="PM cleanup silently succeeds after both group waits expire",
        path="scripts/verdictui_pm_swift.py",
        old=(
            "    raise subprocess.TimeoutExpired(\n"
            '        getattr(proc, "args", f"process group {proc.pid}"),\n'
            "        2 * S.TIMEOUT_PROC_TERM_GRACE,\n    )"
        ),
        new="    return",
        test=(
            "Tests/test_verdictui_pm.py::TestOwnedGroupDescendants"
            "::test_group_that_outlives_both_grace_periods_is_reported"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # CIS-D1582551: a dark launch on a Light host did not get dark, so its
        # colours say nothing about the app.
        name="appearance sweep judges a dark launch the host never realised",
        path="scripts/appearance-sweep.py",
        old='if host_dark is not None and host_dark.get("dark") is not True:',
        new="if False:",
        test=(
            "Tests/test_appearance_sweep.py"
            "::test_a_dark_launch_on_a_light_host_is_unavailable_not_failed_or_passed"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # CIS-9FB9263C: fixed-offset slicing turns `FFFFFF` into a plausible
        # but wrong brightness instead of an error.
        name="appearance sweep luminance accepts a colour that is not #RRGGBB",
        path="scripts/appearance-sweep.py",
        old="    if not _HEX_COLOR.fullmatch(hex_color):\n",
        new="    if False:\n",
        test="Tests/test_appearance_sweep.py::test_luminance_refuses_anything_but_rrggbb",
        runner=Runner.PYTEST,
    ),
    Mutation(
        # CIS-9FB9263C: an uncaught launch failure exits 1, which reads as a
        # defect in the app; an unmeasured launch must reach the verdict as 2.
        name="appearance sweep crashes instead of reporting a failed launch unmeasured",
        path="scripts/appearance-sweep.py",
        old="    except (subprocess.SubprocessError, OSError) as error:\n",
        new="    except OSError as error:\n",
        test=(
            "Tests/test_appearance_sweep.py"
            "::test_measure_is_unmeasured_not_a_crash_when_the_launch_fails"
        ),
        runner=Runner.PYTEST,
    ),
]
