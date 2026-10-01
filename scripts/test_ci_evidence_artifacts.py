#!/usr/bin/env python3.14
"""VerdictUI-only CI contracts that sit beside the shared run-v2 identity harness.

scripts/test_ci_evidence_identity.py must stay byte-identical to the Agents
reference (fleet conformance, CIS-1A534A20), so checks that only make sense for
this repo's workflows live here: the run-v2 artifact name agreed between the
producer upload and the ci-evidence-ref download, and the fixture interpreter
the Swift tests use.
"""

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_ci_evidence_identity as harness  # noqa: E402

EVIDENCE_REF_WORKFLOW_RELPATH = ".github/workflows/ci-evidence-ref.yml"
RUN_V2_ARTIFACT_PREFIX = "run-v2-evidence-"
PRODUCER_ARTIFACT_NAME = RUN_V2_ARTIFACT_PREFIX + "${{ github.sha }}"
CONSUMER_ARTIFACT_SHELL_NAME = RUN_V2_ARTIFACT_PREFIX + "${HEAD_SHA}"
EVIDENCE_REF_WORKFLOW_TEXT = (harness.REPO_ROOT / EVIDENCE_REF_WORKFLOW_RELPATH).read_text(
    encoding="utf-8"
)


def upload_artifact_name(workflow_text: str) -> str:
    upload = harness.extract_step(workflow_text, harness.UPLOAD_NAME)
    in_with = False
    for ln in upload.splitlines():
        if re.match(r"\s*with:\s*$", ln):
            in_with = True
            continue
        if in_with:
            match = re.match(r"\s*name:\s*(.+)$", ln)
            if match:
                return match.group(1).strip()
    raise AssertionError("upload-artifact with.name not found in upload step")


class TestFixturePython(unittest.TestCase):
    def test_fixture_python_is_configured_before_swift_tests(self):
        setup = harness.extract_step(harness.WORKFLOW_TEXT, "Set up fixture Python")
        tests = harness.extract_step(harness.WORKFLOW_TEXT, "Test (zero-warning)")
        self.assertIn("id: fixture_python", setup)
        self.assertIn("python-version: '3.14'", setup)
        self.assertRegex(setup, r"uses: actions/setup-python@[a-f0-9]{40}")
        self.assertLess(harness.WORKFLOW_TEXT.index(setup), harness.WORKFLOW_TEXT.index(tests))
        self.assertIn(
            harness.identity_env_line(
                "VERDICTUI_TEST_PYTHON", "steps.fixture_python.outputs.python-path"
            ),
            tests,
        )


class TestArtifactNameContract(unittest.TestCase):
    def test_producer_upload_artifact_name_matches_contract(self):
        self.assertEqual(upload_artifact_name(harness.WORKFLOW_TEXT), PRODUCER_ARTIFACT_NAME)

    def test_consumer_download_artifact_name_matches_contract(self):
        needle = f'--name "{CONSUMER_ARTIFACT_SHELL_NAME}"'
        self.assertIn(needle, EVIDENCE_REF_WORKFLOW_TEXT)

    def test_consumer_head_sha_binds_to_workflow_run_commit(self):
        self.assertRegex(
            EVIDENCE_REF_WORKFLOW_TEXT,
            r"HEAD_SHA:\s*\$\{\{\s*github\.event\.workflow_run\.head_sha\s*\}\}",
        )


if __name__ == "__main__":
    unittest.main()
