"""An installed launcher must initialize from VerdictUI's own project checkout."""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

_ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.skipif(
    not (_ROOT / ".build/debug/verdictui").is_file(),
    reason="real CLI unavailable in Python-only CI; the PM builds it before this acceptance check",
)
def test_external_launcher_reaches_the_project_runner(tmp_path: Path) -> None:
    root = _ROOT
    launcher = root / ".build/debug/verdictui"
    assert launcher.is_file(), "build the real CLI before exercising project MCP startup"
    external = tmp_path / "verdictui-installed"
    shutil.copy2(launcher, external)
    requests = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "project-bootstrap-check", "version": "1"},
            },
        },
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": "list_scenarios", "arguments": {}},
        },
    ]
    result = subprocess.run(  # nosec B603 — private copy of this checkout's built CLI.
        [str(external), "mcp"],
        cwd=root,
        input="".join(json.dumps(request) + "\n" for request in requests),
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    replies = {item["id"]: item for item in map(json.loads, result.stdout.splitlines())}
    assert set(replies) == {1, 2, 3}, result.stdout
    assert all("error" not in reply for reply in replies.values()), result.stdout
    assert len(replies[2]["result"]["tools"]) == 18
    assert replies[3]["result"].get("isError") is not True
    assert "demo-clean-settings" in json.dumps(replies[3])
