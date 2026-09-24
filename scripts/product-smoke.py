#!/usr/bin/env python3
"""Accept an actual VerdictUI executable against disposable real apps and browsers.

No installed app/account is modified. Failure or unavailable measurement is a failed
acceptance run, never a skip. Run with --binary /absolute/path/to/verdictui.
"""

import argparse
import contextlib
import functools
import hashlib
import http.server
import json
import os
import plistlib
import queue
import signal
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import IO

# INT32_MAX: a pid no live process holds, so the live check must report unavailable.
UNUSED_PID = 2147483647
# Poll interval for eventually(); short so a met condition is seen promptly.
POLL_SECONDS = 0.05


class AcceptanceError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise AcceptanceError(message)


class SecretAudit:
    """Reject credential material in artifact evidence without echoing it."""

    def __init__(self, values):
        self.values = tuple(values)
        self.channels = set()
        self.argv_counts = {"CLI": 0, "MCP": 0, "browser": 0}

    def scan(self, channel, value):
        text = value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value
        if not isinstance(text, str):
            text = json.dumps(text, ensure_ascii=False)
        # Check raw wire text and its decoded JSON, including MCP's JSON-in-text
        # content. Error messages name only the channel, never the matched value.
        candidates = [text]
        while candidates:
            candidate = candidates.pop()
            if isinstance(candidate, str):
                if any(secret in candidate for secret in self.values):
                    raise AcceptanceError(f"credential leak detected in {channel}")
                try:
                    decoded = json.loads(candidate)
                except ValueError:
                    continue
                if decoded != candidate:
                    candidates.append(decoded)
            elif isinstance(candidate, dict):
                candidates.extend(candidate.keys())
                candidates.extend(candidate.values())
            elif isinstance(candidate, list):
                candidates.extend(candidate)
        self.channels.add(channel)

    def process(self, pid, role, process=None):
        measured = subprocess.run(
            ["/bin/ps", "-ww", "-p", str(pid), "-o", "command="],
            capture_output=True,
            timeout=5,
        )
        if measured.returncode != 0 or not measured.stdout.strip():
            # A short CLI may exit before ps observes it. The final gate still
            # requires at least one actual live argv sample for every role.
            if process is not None and process.poll() is not None:
                return
            raise AcceptanceError(f"could not measure owned {role} process arguments")
        self.scan(f"{role} argv", measured.stdout)
        self.argv_counts[role] += 1

    def finish(self):
        required = {
            "CLI stdout",
            "CLI stderr",
            "CLI verdict JSON",
            "MCP stdout",
            "MCP stderr",
            "MCP verdict JSON",
        }
        require(
            required <= self.channels and all(self.argv_counts.values()),
            "credential audit omitted output channels or owned process arguments",
        )
        return {"channels": sorted(self.channels), "argvSamples": dict(self.argv_counts)}


def verdict(value, expected="PASS"):
    require(
        isinstance(value, dict) and value.get("status") == expected,
        f"expected {expected} verdict, got {value}",
    )
    require(isinstance(value.get("findings"), list), "verdict omitted evidence array")
    if expected == "FAIL":
        require(bool(value["findings"]), "FAIL omitted findings")


def nodes(tree, parent=None):
    if "ids" in tree:
        require(bool(tree["ids"]), "empty compact tree")
        for i, identity in enumerate(tree["ids"]):
            text_id = tree["textIDs"][i]
            parent_index = tree.get("parents", [-1] * len(tree["ids"]))[i]
            yield {
                "id": identity,
                "text": tree["strings"][text_id] if text_id >= 0 else None,
                "role": tree["strings"][tree["roleIDs"][i]] if "roleIDs" in tree else None,
                "_parent": tree["ids"][parent_index] if parent_index >= 0 else None,
                "structuralPath": tree.get("structuralPaths", [""] * len(tree["ids"]))[i],
            }
    else:
        require(
            "id" in tree and isinstance(tree.get("children", []), list), "invalid semantic tree"
        )
        yield dict(tree, _parent=parent)
        for child in tree.get("children", []):
            yield from nodes(child, tree["id"])


def target(tree, text, actionable=False):
    observed = list(nodes(tree))
    found = [node for node in observed if node.get("text") == text]
    by_id = {node["id"]: node for node in observed}
    targets = {}
    for selected in found:
        while actionable and selected.get("role") not in {"button", "textField", "link"}:
            require(selected.get("_parent") in by_id, f"no actionable ancestor for {text!r}")
            selected = by_id[selected["_parent"]]
        targets[selected["id"]] = selected
    require(
        len(targets) == 1, f"expected exactly one observed target {text!r}, found {len(targets)}"
    )
    return next(iter(targets.values()))


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def eventually(predicate, message, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(POLL_SECONDS)
    raise AcceptanceError(message)


def required_stream(stream: IO[str] | None) -> IO[str]:
    if stream is None:
        raise AcceptanceError("subprocess omitted requested pipe")
    return stream


class MCP:
    def __init__(self, binary, directory, environment, audit):
        self.audit = audit
        self.closed = False
        self.captured_stdout = []
        self.stderr = tempfile.TemporaryFile()
        self.proc = subprocess.Popen(
            [str(binary), "mcp"],
            cwd=directory,
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr,
            text=True,
            bufsize=1,
        )
        self.input = required_stream(self.proc.stdin)
        self.output = required_stream(self.proc.stdout)
        self.lines = queue.Queue()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        self.sequence = 0
        try:
            self.audit.process(self.proc.pid, "MCP")
            initialized = self.rpc(
                "initialize",
                {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "product-smoke", "version": "1"},
                },
            )
            require("protocolVersion" in initialized, "MCP initialize missing result")
            self.input.write(
                json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"
            )
            self.input.flush()
            self.schemas = {
                tool["name"]: tool["inputSchema"] for tool in self.rpc("tools/list")["tools"]
            }
        except BaseException:
            self.close(terminate=True)
            raise

    def _read(self):
        for line in self.output:
            self.captured_stdout.append(line)
            self.lines.put(line)
        self.lines.put(None)

    def rpc(self, method, params=None):
        self.sequence += 1
        self.input.write(
            json.dumps(
                {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params or {}}
            )
            + "\n"
        )
        self.input.flush()
        try:
            line = self.lines.get(timeout=40)
        except queue.Empty as error:
            raise AcceptanceError(f"MCP response timed out: {method}") from error
        require(line is not None, "MCP exited without response")
        self.audit.scan("MCP stdout", line)
        response = json.loads(line)
        self.audit.scan("MCP verdict JSON", response)
        require(
            response.get("id") == self.sequence and "error" not in response, "MCP protocol error"
        )
        require("result" in response, "MCP omitted result")
        return response["result"]

    def call(self, name, *, unavailable=False, **arguments):
        if hasattr(self, "schemas"):
            require(name in self.schemas, f"installed MCP lacks {name}")
            schema = self.schemas[name]
            require(
                set(arguments) <= set(schema.get("properties", {})), f"unknown arguments for {name}"
            )
            require(
                set(schema.get("required", [])) <= set(arguments),
                f"missing required arguments for {name}",
            )
        result = self.rpc("tools/call", {"name": name, "arguments": arguments})
        require(
            result.get("isError") is unavailable, f"{name} unexpected unavailable status: {result}"
        )
        content = result.get("content")
        require(
            isinstance(content, list) and len(content) == 1 and content[0].get("type") == "text",
            "missing MCP evidence",
        )
        if unavailable:
            require(bool(content[0].get("text")), "unavailable response omitted reason")
            return content[0]["text"]
        return json.loads(content[0]["text"])

    def close(self, terminate=False):
        if self.closed:
            return
        timeout = False
        try:
            if self.proc.poll() is None:
                if terminate:
                    self.proc.send_signal(signal.SIGTERM)
                else:
                    self.input.close()
                try:
                    self.proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait()
                    timeout = True
            self.reader.join(timeout=5)
            require(not self.reader.is_alive(), "MCP output remained open after shutdown")
            self.audit.scan("MCP stdout", "".join(self.captured_stdout))
            self.stderr.seek(0)
            self.audit.scan("MCP stderr", self.stderr.read())
            require(not timeout, "MCP cleanup did not complete")
        finally:
            self.closed = True
            self.stderr.close()


class Smoke:
    def __init__(self, binary, root, temporary):
        self.binary, self.root, self.tmp = binary, root, temporary

        self.env = dict(
            os.environ,
            VERDICTUI_WEB_PROFILE_ROOT=str(temporary / "profiles"),
            VERDICTUI_WEB_CRED_SMOKE_GOOD="vui-good-" + uuid.uuid4().hex,
            VERDICTUI_WEB_OP="",
            VERDICTUI_WEB_CRED_SMOKE_BAD="vui-bad-" + uuid.uuid4().hex,
        )
        self.audit = SecretAudit(
            [self.env["VERDICTUI_WEB_CRED_SMOKE_GOOD"], self.env["VERDICTUI_WEB_CRED_SMOKE_BAD"]]
        )
        self.socket = str(temporary / "daemon.sock")
        self.checks = []
        self.browser_pids = []

    def capture_cli(self, args, timeout=50):
        process = subprocess.Popen(
            [str(self.binary), *map(str, args)],
            cwd=self.tmp,
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            self.audit.process(process.pid, "CLI", process=process)
            stdout, stderr = process.communicate(timeout=timeout)
        except BaseException:
            process.kill()
            stdout, stderr = process.communicate()
            self.audit.scan("CLI stdout", stdout)
            self.audit.scan("CLI stderr", stderr)
            raise
        self.audit.scan("CLI stdout", stdout)
        self.audit.scan("CLI stderr", stderr)
        return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)

    def cli(self, *args, code=0):
        process = self.capture_cli(args)
        require(
            process.returncode == code,
            f"CLI {args[0:2]} exit {process.returncode}, expected {code}: {process.stderr[:1000]}",
        )
        try:
            result = json.loads(process.stdout)
        except ValueError as error:
            raise AcceptanceError(f"CLI {args[0:2]} omitted JSON") from error
        self.audit.scan("CLI verdict JSON", result)
        return result

    def web(self, operation, *args, code=0):
        return self.cli("web", operation, *args, "--socket", self.socket, code=code)

    def browser(self, url):
        info = self.web("open", url + "/clean.html", "--profile", "cli")
        require(len(info) == 1 and alive(info[0]["pid"]), "CLI browser not alive")
        self.browser_pids.append(info[0]["pid"])
        self.audit.process(info[0]["pid"], "browser")
        tree = self.web("render", "--profile", "cli")
        save = target(tree, "Save task", actionable=True)
        verdict(self.web("verify", "--profile", "cli", "--expect-text", "Ready to verify"))
        verdict(
            self.web("verify", "--profile", "cli", "--expect-text", "missing-state", code=1), "FAIL"
        )
        verdict(
            self.web(
                "act",
                "--profile",
                "cli",
                "--action",
                "click",
                "--node",
                save["id"],
                "--expect-text",
                "Task complete",
            )
        )
        self.web("close", "--profile", "cli")
        eventually(lambda: not alive(info[0]["pid"]), "CLI close leaked Chrome")
        self.web("verify", "--profile", "cli", code=2)
        self.checks.append("cli-web-0-1-2-act-close")
        password_hash = hashlib.sha256(
            self.env["VERDICTUI_WEB_CRED_SMOKE_GOOD"].encode()
        ).hexdigest()
        login = url + "/login.html?hash=" + password_hash
        with contextlib.ExitStack() as stack:
            mcp = MCP(self.binary, self.tmp, self.env, self.audit)
            stack.callback(mcp.close)
            tools = mcp.rpc("tools/list")["tools"]
            require(
                {
                    "web_open",
                    "web_render",
                    "web_verify",
                    "web_act",
                    "web_close",
                    "live_inspect",
                    "live_act",
                    "live_verify",
                }
                <= {tool["name"] for tool in tools},
                "installed MCP missing product tools",
            )
            first = mcp.call("web_open", profile="login", url=login)[0]
            self.audit.process(first["pid"], "browser")
            isolated = MCP(self.binary, self.tmp, self.env, self.audit)
            stack.callback(isolated.close)
            isolated.call("web_open", profile="login", url=login, unavailable=True)
            second = isolated.call("web_open", profile="isolated", url=login)[0]
            self.audit.process(second["pid"], "browser")
            require(first["pid"] != second["pid"], "profiles share a browser")
            for credential, expected in (("SMOKE_BAD", "FAIL"), ("SMOKE_GOOD", "PASS")):
                tree = mcp.call("web_render", profile="login")
                password = target(tree, "Password", actionable=True)
                mcp.call(
                    "web_act",
                    profile="login",
                    action="credential",
                    node=password["id"],
                    credential=credential,
                )
                tree = mcp.call("web_render", profile="login")
                result = mcp.call(
                    "web_act",
                    profile="login",
                    action="click",
                    node=target(tree, "Sign in", actionable=True)["id"],
                    expect_text="Welcome",
                )
                verdict(result, expected)
                self.audit.process(first["pid"], "browser")
                self.audit.process(mcp.proc.pid, "MCP")
            tree = mcp.call("web_render", profile="login")
            verdict(
                mcp.call(
                    "web_act",
                    profile="login",
                    action="click",
                    node=target(tree, "Complete task", actionable=True)["id"],
                    expect_text="Task complete",
                )
            )
            verdict(
                isolated.call("web_verify", profile="isolated", expect_text="Task complete"), "FAIL"
            )
            mcp.call("web_close", profile="login")
            eventually(lambda: not alive(first["pid"]), "MCP close leaked Chrome")
            reopened = mcp.call("web_open", profile="login", url=login)[0]
            self.audit.process(reopened["pid"], "browser")
            verdict(mcp.call("web_verify", profile="login", expect_text="Task complete"))
            mcp.call("web_verify", profile="nonexistent", unavailable=True)
            pids = [second["pid"], reopened["pid"]]
            mcp.close()
            isolated.close()
            for pid in pids:
                eventually(lambda pid=pid: not alive(pid), "MCP EOF leaked Chrome")
        other = MCP(self.binary, self.tmp, self.env, self.audit)
        try:
            pid = other.call("web_open", profile="term", url=url + "/clean.html")[0]["pid"]
            self.audit.process(pid, "browser")
            other.close(terminate=True)
            eventually(lambda pid=pid: not alive(pid), "MCP TERM leaked Chrome")
        finally:
            other.close()
        self.checks.append("mcp-login-wrong-fail-right-task-pass-isolation-persistence-eof-term")

    def native(self, url):
        bundle = self.tmp / "LiveFixture.app"
        contents = bundle / "Contents"
        executable = contents / "MacOS/Fixture"
        executable.parent.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleExecutable": "Fixture",
                    "CFBundlePackageType": "APPL",
                    "CFBundleIdentifier": "com.vohux.verdictui.product-smoke",
                    "LSUIElement": True,
                }
            )
        )
        self.compile(self.root / "examples/LiveAppFixture/Fixture.swift", executable)
        observation = self.tmp / "observe.swift"
        observation.write_text(
            "import AppKit\nlet p = NSEvent.mouseLocation\n"
            'let data = try JSONSerialization.data(withJSONObject: ["pid": Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1), "x": p.x, "y": p.y])\n'
            "print(String(decoding: data, as: UTF8.self))\n"
        )
        observer = self.tmp / "observe"
        self.compile(observation, observer, library=False)

        def observe():
            return json.loads(subprocess.check_output([str(observer)], timeout=5))

        for mode in ("appkit", "swiftui"):
            state_file = self.tmp / (mode + ".json")
            before = observe()
            subprocess.run(
                ["/usr/bin/open", "-gj", "-n", "-a", str(bundle), "--args", str(state_file), mode],
                check=True,
                timeout=10,
            )

            def state(state_file=state_file):
                try:
                    return json.loads(state_file.read_text())
                except OSError, ValueError:
                    return None

            initial = eventually(state, "native fixture did not start")
            pid = initial["pid"]
            try:
                require(initial["alpha"] == 0, "fixture is visible")
                tree = self.cli("live", "inspect", "--pid", pid)
                canvas = target(tree, "Native input canvas")
                verdict(self.cli("live", "verify", "--pid", pid, "--expect-text", "clicks=0"))
                verdict(
                    self.cli(
                        "live", "verify", "--pid", pid, "--expect-text", "unseen-state", code=1
                    ),
                    "FAIL",
                )
                result = self.cli(
                    "live",
                    "act",
                    "--pid",
                    pid,
                    "--path",
                    canvas["structuralPath"],
                    "--action",
                    "click",
                    "--expect-text",
                    "clicks=1",
                )
                require(
                    result.get("status") == "PASS" and result.get("delta") is not None,
                    "native action omitted observed delta",
                )
                eventually(
                    lambda: (state() or {}).get("clicks") == 1, "native app did not receive click"
                )
                verdict(self.cli("live", "verify", "--pid", pid, "--expect-text", "clicks=1"))
                self.cli(
                    "live",
                    "act",
                    "--pid",
                    pid,
                    "--path",
                    "not-a-real-path",
                    "--action",
                    "click",
                    code=2,
                )
                native_mcp = MCP(self.binary, self.tmp, self.env, self.audit)
                try:
                    observed = native_mcp.call("live_inspect", pid=pid)
                    live_canvas = target(observed, "Native input canvas")
                    acted = native_mcp.call(
                        "live_act",
                        pid=pid,
                        path=live_canvas["structuralPath"],
                        action="type",
                        value="Fixture",
                        expect_text="text=Fixture",
                    )
                    require(
                        acted.get("status") == "PASS" and acted.get("delta") is not None,
                        "MCP native act omitted observed outcome",
                    )
                    verdict(native_mcp.call("live_verify", pid=pid, expect_text="text=Fixture"))
                    verdict(
                        native_mcp.call("live_verify", pid=pid, expect_text="unseen-state"), "FAIL"
                    )
                    native_mcp.call("live_verify", pid=2147483647, unavailable=True)
                    eventually(
                        lambda: (state() or {}).get("text") == "Fixture",
                        "MCP native input not received",
                    )
                finally:
                    native_mcp.close()
                self.project_checks(url, pid)
                require(
                    observe() == before, "native fixture changed foreground app or global cursor"
                )
            finally:
                if alive(pid):
                    os.kill(pid, signal.SIGTERM)
                eventually(lambda pid=pid: not alive(pid), "native fixture did not exit")
            self.checks.append(
                "installed-native-" + mode + "-act-observe-0-1-2-no-focus-or-cursor-change"
            )

    @staticmethod
    def compile(source, executable, library=True):
        command = [
            "/usr/bin/xcrun",
            "swiftc",
            "-warnings-as-errors",
            "-strict-concurrency=complete",
        ]
        if library:
            command.append("-parse-as-library")
        result = subprocess.run(
            [*command, str(source), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=90,
        )
        require(result.returncode == 0, "fixture compilation failed: " + result.stderr)

    def project_checks(self, url, pid):
        project = self.tmp / "checked-project"
        config = project / ".verdictui/checks.json"
        config.parent.mkdir(parents=True, exist_ok=True)
        checks = [
            {
                "name": "web",
                "kind": "web",
                "url": url + "/clean.html",
                "expectText": "Ready to verify",
            },
            {"name": "native", "kind": "live", "pid": pid, "expectText": "clicks=1"},
        ]
        for expected, code in (("pass", 0), ("fail", 1), ("unavailable", 2)):
            if code == 1:
                checks[0]["expectText"] = "unseen-state"
            elif code == 2:
                checks[1]["pid"] = UNUSED_PID
            config.write_text(json.dumps({"checks": checks}))
            result = self.cli("check", "--project", project, code=code)
            require(
                result.get("status") == expected and len(result.get("checks", [])) == 2,
                "project checks omitted targets/status",
            )
        config.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    args = parser.parse_args()
    require(
        args.binary.is_absolute() and os.access(args.binary, os.X_OK),
        "--binary must be an executable absolute path",
    )
    root = Path(__file__).resolve().parents[1]

    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_args):
            pass

    handler = functools.partial(
        QuietHandler, directory=str(root / "Tests/VerdictUIWebTests/Fixtures")
    )
    with tempfile.TemporaryDirectory(prefix="vui-smoke-", dir="/tmp") as directory:
        artifact_hash = hashlib.sha256(args.binary.read_bytes()).hexdigest()
        smoke = Smoke(args.binary.resolve(), root, Path(directory))
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}"
            smoke.browser(url)
            smoke.native(url)
            require(
                hashlib.sha256(args.binary.read_bytes()).hexdigest() == artifact_hash,
                "binary changed during acceptance",
            )
        finally:
            stopped = smoke.capture_cli(("daemon", "stop", "--socket", smoke.socket), timeout=15)
            require(stopped.returncode == 0, "daemon stop failed")
            for pid in smoke.browser_pids:
                eventually(
                    lambda pid=pid: not alive(pid),
                    "daemon shutdown leaked owned browser",
                    timeout=15,
                )
            server.shutdown()
            server.server_close()
        secret_evidence = smoke.audit.finish()
        smoke.checks.append("artifact-secret-scan-cli-mcp-browser-argv-and-shutdown-streams")
        print(
            json.dumps(
                {
                    "status": "PASS",
                    "binary": str(args.binary),
                    "sha256": artifact_hash,
                    "checks": smoke.checks,
                    "secretAudit": secret_evidence,
                }
            )
        )


if __name__ == "__main__":
    main()
