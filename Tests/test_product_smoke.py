"""Acceptance assertions must reject missing evidence and false clean responses."""

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location(
    "product_smoke", Path(__file__).resolve().parents[1] / "scripts/product-smoke.py"
)
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
                patch.object(smoke.subprocess, "run", return_value=result),
                self.assertRaises(smoke.AcceptanceError),
            ):
                runner.cli("live", "verify")

    def test_zero_exit_without_json_does_not_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = smoke.Smoke(Path("/fixture-binary"), Path(directory), Path(directory))
            with patch.object(
                smoke.subprocess, "run", return_value=Mock(returncode=0, stdout="", stderr="")
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
        with self.assertRaises(smoke.AcceptanceError):
            smoke.target({"id": "text", "role": "text", "text": "Save"}, "Save", actionable=True)

    def test_unknown_request_field_cannot_silently_drop_expectation(self):
        mcp = object.__new__(smoke.MCP)
        mcp.schemas = {"live_verify": {"properties": {"pid": {}, "expect_text": {}}}}
        mcp.rpc = Mock()
        with self.assertRaises(smoke.AcceptanceError):
            mcp.call("live_verify", pid=123, expectText="must be observed")
        mcp.rpc.assert_not_called()


if __name__ == "__main__":
    unittest.main()
