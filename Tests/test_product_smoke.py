"""Acceptance assertions must reject missing evidence and false clean responses."""

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location(
    "product_smoke", Path(__file__).resolve().parents[1] / "scripts/product-smoke.py"
)
assert SPEC is not None and SPEC.loader is not None
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)


class ProductSmokeAssertions(unittest.TestCase):
    def test_empty_or_unavailable_verdict_cannot_pass(self):
        for value in (
            {},
            {"status": "unavailable"},
            {"status": "PASS"},
            {"status": "FAIL", "findings": []},
        ):
            with self.subTest(value=value), self.assertRaises(smoke.AcceptanceError):
                smoke.verdict(value)

    def test_fail_requires_cited_evidence(self):
        with self.assertRaises(smoke.AcceptanceError):
            smoke.verdict({"status": "FAIL", "findings": []}, "FAIL")
        smoke.verdict(
            {"status": "FAIL", "findings": [{"rule": "expected-text", "nodeID": "status"}]}, "FAIL"
        )

    def test_missing_or_ambiguous_observed_target_rejected(self):
        tree = {
            "id": "root",
            "children": [
                {"id": "a", "text": "Save", "children": []},
                {"id": "b", "text": "Save", "children": []},
            ],
        }
        for name in ("missing", "Save"):
            with self.assertRaises(smoke.AcceptanceError):
                smoke.target(tree, name)

    def test_empty_tree_rejected(self):
        for tree in ({}, {"ids": []}):
            with self.assertRaises(smoke.AcceptanceError):
                list(smoke.nodes(tree))

    def test_compact_tree_targets_are_actual_observed_ids(self):
        tree = {
            "ids": ["actual-id"],
            "textIDs": [0],
            "strings": ["Save"],
            "structuralPaths": ["0/1"],
        }
        self.assertEqual(smoke.target(tree, "Save")["id"], "actual-id")

    def test_mcp_unavailable_cannot_be_mistaken_for_pass(self):
        mcp = object.__new__(smoke.MCP)
        mcp.rpc = Mock(
            return_value={"isError": True, "content": [{"type": "text", "text": "unavailable"}]}
        )
        with self.assertRaises(smoke.AcceptanceError):
            mcp.call("web_verify")
        self.assertEqual(mcp.call("web_verify", unavailable=True), "unavailable")

    def test_mcp_missing_content_cannot_pass(self):
        mcp = object.__new__(smoke.MCP)
        for value in (
            {"isError": False, "content": []},
            {"content": [{"type": "text", "text": "{}"}]},
        ):
            mcp.rpc = Mock(return_value=value)
            with self.assertRaises(smoke.AcceptanceError):
                mcp.call("web_render")

    def test_nonzero_cli_unavailable_does_not_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = smoke.Smoke(Path("/fixture-binary"), Path(directory), Path(directory))
            result = Mock(
                returncode=2, stdout='{"status":"PASS","findings":[]}', stderr="unavailable"
            )
            with (
                patch.object(runner, "capture_cli", return_value=result),
                self.assertRaises(smoke.AcceptanceError),
            ):
                runner.cli("live", "verify")

    def test_zero_exit_without_json_does_not_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = smoke.Smoke(Path("/fixture-binary"), Path(directory), Path(directory))
            with patch.object(
                runner, "capture_cli", return_value=Mock(returncode=0, stdout="", stderr="")
            ):
                with self.assertRaises(smoke.AcceptanceError):
                    runner.cli("web", "render")

    def test_timeout_is_failure_not_skip(self):
        with self.assertRaises(smoke.AcceptanceError):
            smoke.eventually(lambda: False, "never observed", timeout=0)

    def test_named_leaf_targets_its_observed_actionable_ancestor(self):
        tree = {
            "id": "button",
            "role": "button",
            "children": [{"id": "label", "role": "text", "text": "Save"}],
        }
        self.assertEqual(smoke.target(tree, "Save", actionable=True)["id"], "button")
        tree["text"] = "Save"
        self.assertEqual(smoke.target(tree, "Save", actionable=True)["id"], "button")
        with self.assertRaises(smoke.AcceptanceError):
            smoke.target({"id": "text", "role": "text", "text": "Save"}, "Save", actionable=True)

    def test_unknown_request_field_cannot_silently_drop_expectation(self):
        mcp = object.__new__(smoke.MCP)
        mcp.schemas = {"live_verify": {"properties": {"pid": {}, "expect_text": {}}}}
        mcp.rpc = Mock()
        with self.assertRaises(smoke.AcceptanceError):
            mcp.call("live_verify", pid=123, expectText="must be observed")
        mcp.rpc.assert_not_called()

    def test_credential_leaks_in_wire_nested_json_and_argv_are_rejected_without_echo(self):
        secret = 'unique-fixture-"credential"-\u2603'
        audit = smoke.SecretAudit([secret])
        encoded = json.dumps({"content": [{"text": json.dumps({"value": secret})}]})
        for channel, value in (
            ("CLI stdout", secret),
            ("CLI stderr", secret.encode()),
            ("MCP verdict JSON", encoded),
            ("MCP stderr", "shutdown: " + secret),
            ("browser argv", "browser --unexpected=" + secret),
        ):
            with self.subTest(channel=channel):
                with self.assertRaises(smoke.AcceptanceError) as raised:
                    audit.scan(channel, value)
                self.assertIn(channel, str(raised.exception))
                self.assertNotIn(secret, str(raised.exception))

    def test_missing_secret_audit_channels_or_process_samples_cannot_pass(self):
        audit = smoke.SecretAudit(["unused-fixture-secret"])
        with self.assertRaises(smoke.AcceptanceError):
            audit.finish()
        for channel in (
            "CLI stdout",
            "CLI stderr",
            "CLI verdict JSON",
            "MCP stdout",
            "MCP stderr",
            "MCP verdict JSON",
        ):
            audit.scan(channel, '{"status":"PASS"}')
        audit.argv_counts = {"CLI": 1, "MCP": 1, "browser": 0}
        with self.assertRaises(smoke.AcceptanceError):
            audit.finish()
        audit.argv_counts["browser"] = 1
        self.assertEqual(audit.finish()["argvSamples"]["browser"], 1)

    def test_cli_captured_stderr_is_scanned_before_failure_reporting(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = smoke.Smoke(Path(sys.executable), Path(directory), Path(directory))
            secret = runner.env["VERDICTUI_WEB_CRED_SMOKE_GOOD"]
            code = "import os,sys;sys.stderr.write(os.environ['VERDICTUI_WEB_CRED_SMOKE_GOOD'])"
            with self.assertRaises(smoke.AcceptanceError) as raised:
                runner.capture_cli(("-c", code))
            self.assertEqual(str(raised.exception), "credential leak detected in CLI stderr")
            self.assertNotIn(secret, str(raised.exception))

    def test_actual_owned_process_arguments_are_scanned(self):
        secret = "unique-argv-fixture-sentinel"
        child = smoke.subprocess.Popen([sys.executable, "-c", "import time;time.sleep(30)", secret])
        try:
            with self.assertRaises(smoke.AcceptanceError) as raised:
                smoke.SecretAudit([secret]).process(child.pid, "MCP")
            self.assertEqual(str(raised.exception), "credential leak detected in MCP argv")
        finally:
            child.terminate()
            child.wait(timeout=5)

    def test_mcp_shutdown_output_cannot_escape_scan(self):
        secret = "unique-shutdown-fixture-sentinel"
        for stdout, stderr, channel in (
            ([secret], b"", "MCP stdout"),
            ([], secret.encode(), "MCP stderr"),
        ):
            with self.subTest(channel=channel):
                mcp = object.__new__(smoke.MCP)
                mcp.audit = smoke.SecretAudit([secret])
                mcp.closed = False
                mcp.proc = Mock(poll=Mock(return_value=0))
                mcp.reader = Mock(is_alive=Mock(return_value=False))
                mcp.captured_stdout = stdout
                mcp.stderr = io.BytesIO(stderr)
                with self.assertRaises(smoke.AcceptanceError) as raised:
                    mcp.close()
                self.assertEqual(str(raised.exception), "credential leak detected in " + channel)
                self.assertTrue(mcp.stderr.closed)
                mcp.close()  # repeated teardown must be safe even after a detected leak


if __name__ == "__main__":
    unittest.main()
