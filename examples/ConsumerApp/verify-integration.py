"""Exercise the compiled consumer through the real launcher and MCP transport."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    launcher = Path(sys.argv[1]).resolve()
    root = Path(__file__).resolve().parent
    nested = root / "Sources" / "ConsumerScenarios"

    def run(arguments: list[str], expected: int, cwd: Path = nested) -> str:
        result = subprocess.run(
            [str(launcher), *arguments], cwd=cwd, capture_output=True, text=True, timeout=30
        )
        check(result.returncode == expected, f"{arguments}: {result.returncode}: {result.stderr}")
        check("demo-" not in result.stdout, f"borrowed demo catalog: {arguments}")
        return result.stdout

    check(json.loads(run(["list"], 0)) == ["consumer-fault", "consumer-settings"], "registry")
    clean = json.loads(run(["verify", "consumer-settings"], 0))
    check(clean["status"] == "PASS" and clean["scenario"] == "consumer-settings", "clean")
    fault = json.loads(run(["verify", "consumer-fault"], 1))
    check(any(f["nodeID"] == "consumer-save" for f in fault["findings"]), "fault evidence")
    run(["verify", "missing"], 2)
    check("consumer-save" in run(["render", "consumer-settings"], 0), "render")
    run(["actions", "consumer-settings"], 0)
    run(["sweep", "consumer-settings", "--locales", "en_US"], 0)

    requests = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "consumer-proof", "version": "1"},
            },
        },
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": "list_scenarios", "arguments": {}},
        },
        {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {"name": "verify", "arguments": {"scenario": "consumer-settings"}},
        },
        {
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": {"name": "verify", "arguments": {"scenario": "consumer-fault"}},
        },
    ]
    wire = subprocess.run(
        [str(launcher), "mcp"],
        cwd=nested,
        input="".join(json.dumps(request) + "\n" for request in requests),
        capture_output=True,
        text=True,
        timeout=30,
    )
    check(wire.returncode == 0, wire.stderr)
    replies = {reply["id"]: reply for reply in map(json.loads, wire.stdout.splitlines())}
    check(len(replies) == 5, "missing MCP replies")
    check("protocolVersion" in replies[1]["result"], "initialize")
    check("tools" in replies[2]["result"], "tools/list")
    check("demo-" not in json.dumps(replies), "MCP borrowed catalog")
    check("consumer-settings" in json.dumps(replies[3]), "MCP custom scenario list")
    for request_id, status in [(4, "PASS"), (5, "FAIL")]:
        payload = json.loads(replies[request_id]["result"]["content"][0]["text"])
        check(payload["status"] == status, f"MCP {status}: {payload}")

    with tempfile.TemporaryDirectory(prefix="verdictui-runner-proof-") as temporary:
        isolated = Path(temporary)
        config = isolated / ".verdictui" / "config.json"
        config.parent.mkdir()
        config.write_text(json.dumps({"runner": str(root / ".build/debug/ConsumerScenarios")}))
        run(["baseline", "consumer-settings", "--update", "--accept"], 0, isolated)
        run(["baseline", "consumer-settings"], 0, isolated)
        check(
            (isolated / "verdict-baselines/consumer-settings.tree.json").exists(), "baseline root"
        )
        invalid = isolated / "not-a-program"
        invalid.write_text("not an executable format")
        invalid.chmod(0o755)
        config.write_text(json.dumps({"runner": str(invalid)}))
        run(["list"], 2, isolated)
        config.write_text('{"runner":"missing"}')
        run(["list"], 2, isolated)
        run(["judge", "missing.json"], 2, isolated)
        config.write_text("not json")
        run(["list"], 2, isolated)
        run(["--help"], 0, isolated)
        proxy = isolated / "proxy"
        proxy.write_text('#!/bin/sh\nexec "$VERDICTUI_TEST_LAUNCHER" "$@"\n')
        proxy.chmod(0o755)
        config.write_text(json.dumps({"runner": str(proxy)}))
        cycle = subprocess.run(
            [str(launcher), "list"],
            cwd=isolated,
            env={**os.environ, "VERDICTUI_TEST_LAUNCHER": str(launcher)},
            capture_output=True,
            text=True,
            timeout=10,
        )
        check(cycle.returncode == 2 and "delegated back" in cycle.stderr, "delegation cycle")
    print("consumer integration PASS: CLI 0/1/2, custom MCP, nested roots, strict manifest, cycle")


if __name__ == "__main__":
    main()
