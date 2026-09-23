"""Exercise the compiled consumer through the real launcher and MCP transport."""

import json
import os
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def reload_proof(launcher: Path, root: Path) -> None:
    """A real separate package changes code while transport PID remains stable."""
    with tempfile.TemporaryDirectory(prefix="vui-reload-", dir="/tmp") as temporary:
        copied = Path(temporary) / "ConsumerApp"
        shutil.copytree(
            root, copied, ignore=shutil.ignore_patterns(".build", ".swiftpm", "__pycache__")
        )
        package = copied / "Package.swift"
        package.write_text(
            package.read_text().replace(
                'path: "../.."', "path: " + json.dumps(str(root.parents[1]))
            )
        )
        source = copied / "Sources/ConsumerScenarios/ConsumerMain.swift"
        original = source.read_text()
        fault = original.replace("faulty ? 6 : 96", "faulty ? 6 : 6").replace(
            "faulty ? 6 : 32", "faulty ? 6 : 6"
        )
        check(original != fault, "source change control absent")
        built = subprocess.run(
            [str(launcher), "list"], cwd=copied, capture_output=True, text=True, timeout=600
        )
        check(built.returncode == 0 and "consumer-settings" in built.stdout, built.stderr)

        def child_of(pid):
            found = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True)
            ids = found.stdout.split()
            check(len(ids) == 1, "broker must own exactly one consumer host")
            return int(ids[0])

        for mode in ("mcp", "daemon"):
            source.write_text(original)
            public_socket = str(Path(temporary) / "broker.sock")
            args = ["mcp"] if mode == "mcp" else ["daemon", "start", "--socket", public_socket]
            with tempfile.TemporaryFile() as log:
                broker = subprocess.Popen(
                    [str(launcher), *args],
                    cwd=copied,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=log,
                    text=True,
                    bufsize=1,
                )

                def rpc(request, mode=mode, broker=broker, public_socket=public_socket):
                    payload = json.dumps(request) + "\n"
                    if mode == "mcp":
                        incoming, outgoing = broker.stdin, broker.stdout
                        if incoming is None or outgoing is None:
                            raise AssertionError("broker protocol pipes unavailable")
                        incoming.write(payload)
                        incoming.flush()
                        with selectors.DefaultSelector() as selector:
                            selector.register(outgoing, selectors.EVENT_READ)
                            check(bool(selector.select(timeout=120)), "broker response timed out")
                        line = outgoing.readline()
                    else:
                        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                            client.settimeout(120)
                            client.connect(public_socket)
                            client.sendall(payload.encode())
                            line = client.makefile("rb").readline().decode()
                    check(bool(line), "broker closed without structured response")
                    return json.loads(line)

                def verify(mode=mode, rpc=rpc):
                    if mode == "mcp":
                        response = rpc(
                            {
                                "jsonrpc": "2.0",
                                "id": 2,
                                "method": "tools/call",
                                "params": {
                                    "name": "verify",
                                    "arguments": {"scenario": "consumer-settings"},
                                },
                            }
                        )["result"]
                        return (
                            None
                            if response["isError"]
                            else json.loads(response["content"][0]["text"])["status"]
                        )
                    response = rpc({"id": "2", "method": "verify", "scenario": "consumer-settings"})
                    return response["result"]["verdict"]["status"] if response["ok"] else None

                try:
                    if mode == "mcp":
                        rpc(
                            {
                                "jsonrpc": "2.0",
                                "id": 1,
                                "method": "initialize",
                                "params": {
                                    "protocolVersion": "2024-11-05",
                                    "capabilities": {},
                                    "clientInfo": {"name": "reload-proof", "version": "1"},
                                },
                            }
                        )
                    else:
                        deadline = time.monotonic() + 60
                        while (
                            not Path(public_socket).exists()
                            and broker.poll() is None
                            and time.monotonic() < deadline
                        ):
                            time.sleep(0.05)
                        check(Path(public_socket).exists(), "broker daemon not ready")
                    check(verify() == "PASS", f"{mode} initial consumer")
                    first_child = child_of(broker.pid)
                    source.write_text(fault)
                    check(verify() == "FAIL", f"{mode} did not rebuild changed source")
                    check(
                        child_of(broker.pid) != first_child and broker.poll() is None,
                        "transport did not remain alive",
                    )
                    os.kill(child_of(broker.pid), signal.SIGKILL)
                    time.sleep(0.1)
                    check(verify() is None, "dead child masqueraded as available")
                    check(verify() == "FAIL", "next request did not recover")
                    source.write_text(original + "\nthis is invalid Swift !!!\n")
                    check(
                        verify() is None and broker.poll() is None,
                        "failed compile served stale verdict or killed broker",
                    )
                    source.write_text(original)
                    check(verify() == "PASS", "fixed source failed to recover")
                finally:
                    if broker.poll() is None:
                        broker.terminate()
                        try:
                            broker.wait(timeout=15)
                        except subprocess.TimeoutExpired:
                            broker.kill()
                            broker.wait()
                            raise
                    if broker.returncode not in (0, -signal.SIGTERM):
                        log.seek(0)
                        print(log.read().decode(), file=sys.stderr)
        print(
            "consumer reload PASS: same MCP/daemon PID, rebuilt state, child kill recovery, failed-build refusal"
        )


def main() -> None:
    launcher = Path(sys.argv[1]).resolve()
    root = Path(__file__).resolve().parent
    if "--reload" in sys.argv[2:]:
        reload_proof(launcher, root)
        return
    if "--cold" in sys.argv[2:]:
        with tempfile.TemporaryDirectory(prefix="verdictui-cold-consumer-") as temporary:
            copied = Path(temporary) / "ConsumerApp"
            shutil.copytree(
                root, copied, ignore=shutil.ignore_patterns(".build", ".swiftpm", "__pycache__")
            )
            package = copied / "Package.swift"
            package.write_text(
                package.read_text().replace(
                    'path: "../.."', "path: " + json.dumps(str(root.parents[1]), ensure_ascii=False)
                )
            )
            check(
                not (copied / ".build/debug/ConsumerScenarios").exists(),
                "cold runner already exists",
            )
            result = subprocess.run(
                [sys.executable, str(copied / Path(__file__).name), str(launcher)],
                cwd=copied,
                timeout=600,
            )
            check(result.returncode == 0, "cold external consumer integration")
        print("cold external consumer auto-build PASS")
        return
    nested = root / "Sources" / "ConsumerScenarios"

    def run(arguments: list[str], expected: int, cwd: Path = nested) -> str:
        result = subprocess.run(
            [str(launcher), *arguments], cwd=cwd, capture_output=True, text=True, timeout=360
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
        timeout=360,
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
        config.write_text(
            json.dumps(
                {
                    "runner": str(root / ".build/debug/ConsumerScenarios"),
                    "buildProduct": "NoSuchProduct",
                }
            )
        )
        failed = run(["list"], 2, isolated)
        check(failed == "", "failed build executed stale runner")
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
