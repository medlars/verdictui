#!/usr/bin/env python3.14
"""Regression harness: every consumer verifier is bound to THIS invocation's producer (CIS-04F12B01)."""

import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CANDIDATE_WORKFLOWS = (".github/workflows/ci.yml", ".github/workflows/test-suite.yml")
WORKFLOW_RELPATH = next(p for p in CANDIDATE_WORKFLOWS if (REPO_ROOT / p).is_file())
EMITTER_NAME = "Emit run-v2 evidence (shadow)"
VERIFIER_NAME = "Verify run-v2 evidence was produced"
UPLOAD_NAME = "Upload run-v2 evidence"
REGRESSION_NAME = "Verify CI evidence identity contract"

WORKFLOW_TEXT = (REPO_ROOT / WORKFLOW_RELPATH).read_text(encoding="utf-8")


def extract_step(workflow_text, name):
    lines = workflow_text.splitlines()
    pattern = re.compile(r"^(\s*)- name: " + re.escape(name) + r"\s*$")
    hits = [i for i, ln in enumerate(lines) if pattern.match(ln)]
    if len(hits) != 1:
        raise AssertionError(f"expected exactly one step named {name!r}, found {len(hits)}")
    start = hits[0]
    indent = len(lines[start]) - len(lines[start].lstrip())
    block = [lines[start]]
    for ln in lines[start + 1 :]:
        stripped = ln.strip()
        if not stripped or stripped.startswith("#"):
            block.append(ln)
            continue
        if len(ln) - len(ln.lstrip()) > indent:
            block.append(ln)
            continue
        break
    return "\n".join(block)


def extract_run(step_text):
    lines = step_text.splitlines()
    run_at = [i for i, ln in enumerate(lines) if re.match(r"^(\s*)run: \|", ln)]
    if len(run_at) != 1:
        raise AssertionError(f"expected exactly one 'run: |' in step, found {len(run_at)}")
    i = run_at[0]
    indent = len(lines[i]) - len(lines[i].lstrip())
    body_lines = []
    for ln in lines[i + 1 :]:
        if not ln.strip():
            body_lines.append("")
            continue
        if len(ln) - len(ln.lstrip()) <= indent:
            break
        body_lines.append(ln)
    body = textwrap.dedent("\n".join(body_lines))
    if "PYVERIFY" not in body:
        raise AssertionError("extracted run body does not contain the PYVERIFY verifier")
    if "${{" in body:
        raise AssertionError("extracted run body still contains unresolved ${{ }} expressions")
    return body


def producer_project(workflow_text):
    emit = extract_step(workflow_text, EMITTER_NAME)
    match = re.search(r"--project\s+(\S+)", emit)
    if not match:
        raise AssertionError("emitter step does not carry a --project argument")
    return match.group(1)


PROJECT = producer_project(WORKFLOW_TEXT)
BODY = extract_run(extract_step(WORKFLOW_TEXT, VERIFIER_NAME))


def base_record():
    return {
        "schema_version": "2.0.0",
        # Top-level run_id is a UUID produced by the emitter and is deliberately
        # NOT the run number; the compared field is runner.identity below. This
        # record passing while run_id != 900001 is the wrong-field positive control.
        "run_id": "11111111-1111-4111-8111-111111111111",
        "project": {"canonical_id": PROJECT},
        "source": {"repo": "audit/example", "commit_sha": "a" * 40},
        "runner": {"kind": "ci", "identity": "github-actions/run/900001"},
        "summary": {"release_verdict": "PASS"},
    }


def run_case(
    tmp,
    *,
    record=None,
    emit_outcome="success",
    key_present=True,
    checkout_outcome=None,
    env_overrides=None,
    evidence_text=None,
    cwd_rel="",
):
    ws = tmp / "ws"
    (ws / "evidence").mkdir(parents=True, exist_ok=True)
    path = ws / "evidence" / "run-v2.json"
    if evidence_text is not None:
        path.write_text(evidence_text, encoding="utf-8")
    elif record is not None:
        path.write_text(json.dumps(record), encoding="utf-8")
    shim = tmp / "bin"
    shim.mkdir(exist_ok=True)
    pyshim = shim / "python"
    if not pyshim.exists():
        pyshim.symlink_to(sys.executable)
    env = os.environ.copy()
    # Prepend the interpreter shim; the rest of PATH is passed through untouched.
    env["PATH"] = str(shim) + os.pathsep + env.get("PATH", "")
    env["GITHUB_STEP_SUMMARY"] = str(tmp / "summary.md")
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["GOV_V2_KEY_PRESENT"] = "true" if key_present else "false"
    # The two carve-out signals come from ONE step outcome, so key_present=False
    # with a successful checkout is a combination the workflow cannot emit; the
    # default pairs them and adversarial cases override explicitly.
    if checkout_outcome is None:
        checkout_outcome = "success" if key_present else "failure"
    env["GOV_V2_CHECKOUT_OUTCOME"] = checkout_outcome
    env["EVIDENCE_EMIT_OUTCOME"] = emit_outcome
    env["EVIDENCE_EXPECTED_RUN_ID"] = "900001"
    env["EVIDENCE_EXPECTED_COMMIT"] = "a" * 40
    env["EVIDENCE_EXPECTED_REPO"] = "audit/example"
    env["EVIDENCE_EXPECTED_PROJECT"] = PROJECT
    env["EVIDENCE_PATH"] = str(path)
    env.update(env_overrides or {})
    cwd = ws / cwd_rel if cwd_rel else ws
    if cwd_rel:
        cwd.mkdir(parents=True, exist_ok=True)
    script = tmp / "verify.sh"
    script.write_text(BODY, encoding="utf-8")
    proc = subprocess.run(
        ["/bin/bash", "-e", str(script)],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    summary_path = Path(env["GITHUB_STEP_SUMMARY"])
    summary = summary_path.read_text(encoding="utf-8") if summary_path.exists() else ""
    return proc.returncode, proc.stdout, proc.stderr, summary


def identity_env_line(key, expression):
    return f"{key}: ${{{{ {expression} }}}}"


class TestCurrentProducerBinding(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="cis04f12b01-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)

    def test_current_producer_current_identity_passes(self):
        rc, out, err, summary = run_case(self.tmp, record=base_record())
        self.assertEqual(rc, 0, msg=err)
        self.assertIn("PRESENT", summary)
        self.assertIn("identity verified", out)
        self.assertIn("belongs to this successful producer invocation", out)

    def test_wrong_field_control_top_level_run_id_uuid_not_compared(self):
        # The base record already carries a UUID run_id different from run 900001
        # and still passes: the verifier compares runner.identity, not run_id.
        record = base_record()
        self.assertNotEqual(record["run_id"], "900001")
        rc, _out, err, summary = run_case(self.tmp, record=record)
        self.assertEqual(rc, 0, msg=err)
        self.assertIn("PRESENT", summary)

    def test_verifier_does_not_grade_tests(self):
        # A red-run record (BLOCKED verdict, FAIL stages) still binds correctly:
        # identity verification must not become a second test grader.
        record = base_record()
        record["summary"] = {"release_verdict": "BLOCKED"}
        record["stages"] = [
            {
                "stage_id": "tests",
                "required": True,
                "applicable": True,
                "state": "FAIL",
                "score": 0.0,
                "reason_code": "ok",
                "duration_s": 0.0,
                "evidence_refs": [],
                "evaluator_version": "pytest/9.0.3",
            },
        ]
        rc, _out, err, summary = run_case(self.tmp, record=record)
        self.assertEqual(rc, 0, msg=err)
        self.assertIn("PRESENT", summary)

    def test_old_run_identity_rejected(self):
        record = base_record()
        record["runner"]["identity"] = "github-actions/run/900000"
        rc, _out, err, summary = run_case(self.tmp, record=record)
        self.assertEqual(rc, 1)
        self.assertIn("runner.identity", err)
        self.assertNotIn("PRESENT", summary)

    def test_wrong_commit_rejected(self):
        record = base_record()
        record["source"]["commit_sha"] = "b" * 40
        rc, _out, err, _summary = run_case(self.tmp, record=record)
        self.assertEqual(rc, 1)
        self.assertIn("commit", err)

    def test_wrong_repo_rejected(self):
        record = base_record()
        record["source"]["repo"] = "audit/other"
        rc, _out, err, _summary = run_case(self.tmp, record=record)
        self.assertEqual(rc, 1)
        self.assertIn("repo", err)

    def test_wrong_project_rejected(self):
        record = base_record()
        record["project"]["canonical_id"] = "another-project"
        rc, _out, err, _summary = run_case(self.tmp, record=record)
        self.assertEqual(rc, 1)
        self.assertIn("project", err)

    def test_non_ci_runner_rejected(self):
        record = base_record()
        record["runner"]["kind"] = "local"
        rc, _out, err, _summary = run_case(self.tmp, record=record)
        self.assertEqual(rc, 1)
        self.assertIn("runner.kind", err)

    def test_spoofed_suffix_rejected_strict_equality(self):
        record = base_record()
        record["runner"]["identity"] = "evil-prefix/github-actions/run/900001"
        rc, _out, _err, summary = run_case(self.tmp, record=record)
        self.assertEqual(rc, 1)
        self.assertNotIn("PRESENT", summary)

    def test_producer_outcome_states(self):
        for outcome in ("failure", "skipped", "cancelled", ""):
            for key_present in (True, False):
                with self.subTest(outcome=outcome, key_present=key_present):
                    with tempfile.TemporaryDirectory(prefix="cis04f12b01-") as d:
                        rc, _out, err, summary = run_case(
                            Path(d),
                            record=base_record(),
                            emit_outcome=outcome,
                            key_present=key_present,
                        )
                    if key_present:
                        self.assertEqual(rc, 1, msg=err)
                        self.assertNotIn("PRESENT", summary)
                    else:
                        # Keyless repo: the skip is loud and visible, never PRESENT.
                        self.assertEqual(rc, 0, msg=err)
                        self.assertNotIn("PRESENT", summary)
                        self.assertIn("produced no run-v2 evidence", summary.lower())

    def test_missing_expected_identity_each_var_blank(self):
        for key in (
            "EVIDENCE_EXPECTED_RUN_ID",
            "EVIDENCE_EXPECTED_COMMIT",
            "EVIDENCE_EXPECTED_REPO",
            "EVIDENCE_EXPECTED_PROJECT",
        ):
            with self.subTest(key=key):
                with tempfile.TemporaryDirectory(prefix="cis04f12b01-") as d:
                    rc, _out, err, summary = run_case(
                        Path(d),
                        record=base_record(),
                        env_overrides={key: ""},
                    )
                self.assertEqual(rc, 1, msg=err)
                self.assertNotIn("PRESENT", summary)

    def test_absent_evidence_file_rejected(self):
        with tempfile.TemporaryDirectory(prefix="cis04f12b01-") as d:
            rc, _out, err, _summary = run_case(Path(d), record=None)
        self.assertEqual(rc, 1, msg=err)

    def test_zero_byte_evidence_file_rejected(self):
        with tempfile.TemporaryDirectory(prefix="cis04f12b01-") as d:
            rc, _out, err, _summary = run_case(Path(d), evidence_text="")
        self.assertEqual(rc, 1, msg=err)

    def test_invalid_json_rejected(self):
        with tempfile.TemporaryDirectory(prefix="cis04f12b01-") as d:
            rc, _out, err, _summary = run_case(Path(d), evidence_text="{not-json")
        self.assertEqual(rc, 1, msg=err)
        self.assertNotIn("Traceback", err)

    def test_wrong_root_type_rejected_without_traceback(self):
        for text in ("[]", "null", "1", '"text"'):
            with self.subTest(root=text):
                with tempfile.TemporaryDirectory(prefix="cis04f12b01-") as d:
                    rc, _out, err, _summary = run_case(Path(d), evidence_text=text)
                self.assertEqual(rc, 1, msg=err)
                self.assertNotIn("Traceback", err)

    def test_wrong_nested_section_type_rejected(self):
        for section in ("source", "runner", "project"):
            for mutate in ("absent", "null", "list", "string"):
                with self.subTest(section=section, mutate=mutate):
                    record = base_record()
                    if mutate == "absent":
                        del record[section]
                    elif mutate == "null":
                        record[section] = None
                    elif mutate == "list":
                        record[section] = []
                    else:
                        record[section] = "oops"
                    with tempfile.TemporaryDirectory(prefix="cis04f12b01-") as d:
                        rc, _out, err, _summary = run_case(Path(d), record=record)
                    self.assertEqual(rc, 1, msg=err)
                    self.assertNotIn("Traceback", err)

    def test_wrong_schema_version_rejected(self):
        for value in ("absent", "9.9.9"):
            with self.subTest(schema=value):
                record = base_record()
                if value == "absent":
                    del record["schema_version"]
                else:
                    record["schema_version"] = value
                with tempfile.TemporaryDirectory(prefix="cis04f12b01-") as d:
                    rc, _out, err, _summary = run_case(Path(d), record=record)
                self.assertEqual(rc, 1, msg=err)

    def test_sentinel_style_subdirectory_cwd_reaches_root_evidence(self):
        with tempfile.TemporaryDirectory(prefix="cis04f12b01-") as d:
            rc, _out, err, summary = run_case(
                Path(d),
                record=base_record(),
                cwd_rel="app",
            )
        self.assertEqual(rc, 0, msg=err)
        self.assertIn("PRESENT", summary)


class TestKeylessCarveOutSignals(unittest.TestCase):
    """The carve-out must fire on an OBSERVED unavailable checkout, never on an
    unobservable one. A renamed checkout step id or a dropped env mapping leaves
    the signals blank, and a blank signal used to take the allow branch --
    CIS-04F12B01 security finding 4. "Unavailable" and "could not observe" demand
    opposite answers, so the verifier needs a third state, not a boolean."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="cis04f12b01-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)

    def test_genuine_keyless_checkout_failure_still_skips_loudly(self):
        # The owner-decided fleet standard (2026-09-12): keep this carve-out.
        rc, _out, err, summary = run_case(
            self.tmp,
            record=base_record(),
            emit_outcome="skipped",
            key_present=False,
            checkout_outcome="failure",
        )
        self.assertEqual(rc, 0, msg=err)
        self.assertNotIn("PRESENT", summary)
        self.assertIn("produced no run-v2 evidence", summary.lower())

    def test_genuine_keyless_checkout_skipped_still_skips_loudly(self):
        rc, _out, err, summary = run_case(
            self.tmp,
            record=base_record(),
            emit_outcome="skipped",
            key_present=False,
            checkout_outcome="skipped",
        )
        self.assertEqual(rc, 0, msg=err)
        self.assertIn("produced no run-v2 evidence", summary.lower())

    def test_blank_key_present_signal_fails_closed(self):
        # A dropped `GOV_V2_KEY_PRESENT` env mapping renders blank.
        rc, out, err, summary = run_case(
            self.tmp,
            record=base_record(),
            emit_outcome="skipped",
            env_overrides={"GOV_V2_KEY_PRESENT": ""},
        )
        self.assertEqual(rc, 1, msg=out)
        self.assertIn("GOV_V2_KEY_PRESENT", err)
        self.assertNotIn("PRESENT", summary)

    def test_unrecognised_key_present_signal_fails_closed(self):
        rc, out, err, _summary = run_case(
            self.tmp,
            record=base_record(),
            emit_outcome="skipped",
            env_overrides={"GOV_V2_KEY_PRESENT": "maybe"},
        )
        self.assertEqual(rc, 1, msg=out)
        self.assertIn("GOV_V2_KEY_PRESENT", err)

    def test_blank_checkout_outcome_fails_closed(self):
        # A renamed checkout step id renders `steps.<id>.outcome` blank, which
        # makes the boolean mapping evaluate to a perfectly plausible "false".
        # Only the outcome signal separates that from a real keyless run.
        rc, out, err, summary = run_case(
            self.tmp,
            record=base_record(),
            emit_outcome="skipped",
            key_present=False,
            checkout_outcome="",
        )
        self.assertEqual(rc, 1, msg=out)
        self.assertIn("GOV_V2_CHECKOUT_OUTCOME", err)
        self.assertNotIn("PRESENT", summary)

    def test_unrecognised_checkout_outcome_fails_closed(self):
        rc, out, err, _summary = run_case(
            self.tmp,
            record=base_record(),
            emit_outcome="skipped",
            key_present=False,
            checkout_outcome="notastate",
        )
        self.assertEqual(rc, 1, msg=out)
        self.assertIn("GOV_V2_CHECKOUT_OUTCOME", err)

    def test_contradictory_signals_fail_closed(self):
        # Both signals derive from one step outcome, so "key absent" plus
        # "checkout succeeded" cannot both be true; observing it means the
        # wiring no longer reports what it claims to report.
        rc, out, _err, summary = run_case(
            self.tmp,
            record=base_record(),
            emit_outcome="skipped",
            key_present=False,
            checkout_outcome="success",
        )
        self.assertEqual(rc, 1, msg=out)
        self.assertNotIn("PRESENT", summary)

    def test_keyed_repo_with_failed_producer_still_fails(self):
        # Positive control for the whole class: the carve-out must not widen
        # into the keyed path this ticket exists to keep red.
        rc, out, err, _summary = run_case(
            self.tmp,
            record=base_record(),
            emit_outcome="failure",
            key_present=True,
        )
        self.assertEqual(rc, 1, msg=out)
        self.assertIn("EVIDENCE_EMIT_OUTCOME", err)


class TestWiring(unittest.TestCase):
    def setUp(self):
        self.verifier = extract_step(WORKFLOW_TEXT, VERIFIER_NAME)

    def test_step_ids_unique(self):
        self.assertEqual(WORKFLOW_TEXT.count("id: runv2_emit"), 1)
        self.assertEqual(WORKFLOW_TEXT.count("id: runv2_verify"), 1)

    def test_govv2_step_id_is_unique_and_precedes_the_verifier(self):
        # `steps.<id>.outcome` reads blank for an unknown OR a later step, so a
        # rename and a reorder both silence the carve-out signals.
        self.assertEqual(WORKFLOW_TEXT.count("id: govv2"), 1)
        self.assertLess(
            WORKFLOW_TEXT.index("id: govv2"),
            WORKFLOW_TEXT.index(f"- name: {VERIFIER_NAME}"),
        )

    def test_keyless_carveout_env_wiring_is_pinned(self):
        # Owner decision 2026-09-12: the carve-out stays, and its wiring is
        # pinned so a silent rewiring flips this control red instead of
        # flipping the verifier to allow (CIS-04F12B01 finding 4).
        self.assertIn(
            identity_env_line("GOV_V2_KEY_PRESENT", "steps.govv2.outcome == 'success'"),
            self.verifier,
        )
        self.assertIn(
            identity_env_line("GOV_V2_CHECKOUT_OUTCOME", "steps.govv2.outcome"),
            self.verifier,
        )

    def test_both_carveout_signals_are_consumed_not_dead_env(self):
        # A mapped-but-unread env var is indistinguishable from an absent one.
        self.assertIn("GOV_V2_KEY_PRESENT", BODY)
        self.assertIn("GOV_V2_CHECKOUT_OUTCOME", BODY)

    def test_verifier_env_uses_emitter_outcome_exactly(self):
        self.assertIn(
            identity_env_line("EVIDENCE_EMIT_OUTCOME", "steps.runv2_emit.outcome"),
            self.verifier,
        )

    def test_identity_env_maps_to_github_expressions(self):
        expected = {
            "EVIDENCE_EXPECTED_RUN_ID": "github.run_id",
            "EVIDENCE_EXPECTED_COMMIT": "github.sha",
            "EVIDENCE_EXPECTED_REPO": "github.repository",
        }
        for key, expression in expected.items():
            self.assertIn(identity_env_line(key, expression), self.verifier)

    def test_expected_project_literal_equals_producer_project(self):
        self.assertIn(f"EVIDENCE_EXPECTED_PROJECT: {PROJECT}", self.verifier)
        # Asserted literally: identity_env_line's ${{ }} wrap would double the
        # closing braces on an expression that already carries a path suffix.
        self.assertIn(
            "EVIDENCE_PATH: ${{ github.workspace }}/evidence/run-v2.json",
            self.verifier,
        )

    def test_verifier_has_no_continue_on_error_and_keeps_cancelled_guard(self):
        self.assertNotIn("continue-on-error", self.verifier)
        if_line = next(ln for ln in self.verifier.splitlines() if ln.strip().startswith("if:"))
        self.assertIn("!cancelled()", if_line)
        self.assertNotIn("success()", if_line)

    def test_upload_guard_conjoins_both_outcomes_and_artifact(self):
        upload = extract_step(WORKFLOW_TEXT, UPLOAD_NAME)
        if_line = next(ln for ln in upload.splitlines() if ln.strip().startswith("if:"))
        self.assertIn("!cancelled()", if_line)
        self.assertIn("steps.runv2_emit.outcome == 'success'", if_line)
        self.assertIn("steps.runv2_verify.outcome == 'success'", if_line)
        self.assertIn("hashFiles('evidence/run-v2.json') != ''", if_line)

    def test_verifier_runs_before_upload(self):
        self.assertLess(
            WORKFLOW_TEXT.index(f"- name: {VERIFIER_NAME}"),
            WORKFLOW_TEXT.index(f"- name: {UPLOAD_NAME}"),
        )

    def test_regression_step_runs_before_the_emitter_on_its_interpreter(self):
        regression = extract_step(WORKFLOW_TEXT, REGRESSION_NAME)
        run_line = next(ln for ln in regression.splitlines() if ln.strip().startswith("run:"))
        self.assertIn('"$GITHUB_WORKSPACE/scripts/test_ci_evidence_identity.py"', run_line)
        # Interpreter PARITY with the emitter, not the presence of a named setup
        # action: some consumers run on images that already provide `python` and
        # never call actions/setup-python, and asserting one spelling of "an
        # interpreter exists" fails for them while saying nothing about whether
        # the interpreter actually resolves. If the emitter can run it, so can
        # this step -- and if it cannot, the emitter is red first.
        emit = extract_step(WORKFLOW_TEXT, EMITTER_NAME)
        interp = re.search(r"(\bpython[0-9.]*) \"\$GOV_V2/scripts/emit_run_evidence\.py\"", emit)
        self.assertIsNotNone(interp, "emitter does not invoke the evidence emitter directly")
        assert interp is not None
        self.assertIn(f'run: {interp.group(1)} "$GITHUB_WORKSPACE', run_line)
        emitter_prefix = WORKFLOW_TEXT[: WORKFLOW_TEXT.index(f"- name: {EMITTER_NAME}")]
        self.assertIn(f"- name: {REGRESSION_NAME}", emitter_prefix)


FIXTURE_STEP = textwrap.dedent("""\
    jobs:
      test:
        steps:
          - name: Emit run-v2 evidence (shadow)
            run: echo hi
""")
FIXTURE_DUPLICATE = textwrap.dedent(
    f"""\
    jobs:
      test:
        steps:
          - name: {VERIFIER_NAME}
            run: |
              echo one
          - name: {VERIFIER_NAME}
            run: |
              echo two
"""
)
FIXTURE_NO_RUN = textwrap.dedent(
    f"""\
    jobs:
      test:
        steps:
          - name: {VERIFIER_NAME}
            uses: actions/checkout@v4
"""
)


class TestExtractionNegatives(unittest.TestCase):
    def test_extract_step_refuses_missing_step(self):
        with self.assertRaises(AssertionError):
            extract_step(FIXTURE_STEP, VERIFIER_NAME)

    def test_extract_step_refuses_duplicate_step(self):
        with self.assertRaises(AssertionError):
            extract_step(FIXTURE_DUPLICATE, VERIFIER_NAME)

    def test_extract_run_refuses_missing_run_body(self):
        with self.assertRaises(AssertionError):
            extract_run(extract_step(FIXTURE_NO_RUN, VERIFIER_NAME))

    def test_extract_run_refuses_body_without_pyverify(self):
        bodyless = FIXTURE_DUPLICATE.replace(VERIFIER_NAME, EMITTER_NAME, 1)
        with self.assertRaises(AssertionError):
            extract_run(extract_step(bodyless, EMITTER_NAME))


if __name__ == "__main__":
    unittest.main(verbosity=2)
