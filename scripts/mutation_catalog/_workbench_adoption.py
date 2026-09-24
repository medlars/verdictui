"""Current build identity admission controls for the real Workbench workflow."""

from mutation_catalog_types import Mutation, Runner

_SOURCE = "scripts/workbench_identity.py"
_TEST = "Tests/test_workbench_identity.py::"

MUTATIONS: list[Mutation] = [
    Mutation(
        name="Workbench source scan ignores byte and file limits",
        path=_SOURCE,
        old="if count > MAX_FILES or total > MAX_BYTES:",
        new="if False:",
        test=_TEST + "test_scan_limits_are_unavailable_not_partial_fingerprints",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Workbench stamps source changed during compilation",
        path=_SOURCE,
        old="if source_fingerprint(root) != before:",
        new="if False:",
        test=_TEST + "test_changed_source_during_build_cannot_receive_stamp",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Workbench accepts a stamp for stale compiled source",
        path=_SOURCE,
        old='receipt.get(\n        "framework_source_sha256"\n    ) != source_fingerprint(root)',
        new="False",
        test=_TEST + "test_current_source_changes_refuse_stale_packaged_app",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Workbench signature failure is ignored",
        path=_SOURCE,
        old='["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],\n        check=True,',
        new='["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],\n        check=False,',
        test=_TEST + "test_failed_signature_cannot_be_admitted",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Workbench accepts substituted packaged assets",
        path=_SOURCE,
        old="if _digest_paths(resources, [resources]) != _digest_paths(actual_resources, [actual_resources]):",
        new="if False:",
        test=_TEST + "test_packaged_assets_cannot_be_substituted_despite_matching_source_stamp",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Workbench accepts nonexecutable packaged helper",
        path=_SOURCE,
        old="if not os.access(binary, os.X_OK) or not os.access(helper, os.X_OK):",
        new="if False:",
        test=_TEST + "test_nonexecutable_or_missing_helper_is_unavailable",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="Workbench accepts consumer with changed fixture sources",
        path=_SOURCE,
        old='if value.get("fixture_source_sha256") != fixture_fingerprint(fixture):',
        new="if False:",
        test=_TEST + "test_consumer_prebuild_requires_actual_current_inputs[fixture]",
        runner=Runner.PYTEST,
    ),
]
