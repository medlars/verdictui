"""Exercise the compiled consumer through the real launcher and MCP transport."""

import ctypes
import errno
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
import uuid
from dataclasses import dataclass
from pathlib import Path

# Poll interval while waiting for the broker socket to appear.
SOCKET_POLL_SECONDS = 0.05


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    parent: int
    group: int
    birth: tuple[int, int]
    executable: str


class _ProcBSDInfo(ctypes.Structure):
    # Public Darwin sys/proc_info.h, PROC_PIDTBSDINFO (not a ps display timestamp).
    _fields_ = (
        [
            (name, ctypes.c_uint32)
            for name in (
                "flags",
                "status",
                "xstatus",
                "pid",
                "ppid",
                "uid",
                "gid",
                "ruid",
                "rgid",
                "svuid",
                "svgid",
                "reserved",
            )
        ]
        + [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
        + [(name, ctypes.c_uint32) for name in ("nfiles", "pgid", "pjobc", "tdev", "tpgid")]
        + [
            ("nice", ctypes.c_int32),
            ("start_seconds", ctypes.c_uint64),
            ("start_microseconds", ctypes.c_uint64),
        ]
    )


def _libproc():
    check(sys.platform == "darwin", "consumer reload identities require macOS")
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    library.proc_pidinfo.restype = ctypes.c_int
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    library.proc_listpids.argtypes = [
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    library.proc_listpids.restype = ctypes.c_int
    return library


def process_identity(pid: int) -> ProcessIdentity | None:
    library = _libproc()
    info = _ProcBSDInfo()
    size = ctypes.sizeof(info)
    ctypes.set_errno(0)
    measured = library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size)
    if measured == 0:
        check(ctypes.get_errno() == errno.ESRCH, "process identity unavailable")
        return None
    if measured == size and info.status == 5:  # SZOMB
        return None
    check(measured == size, "incomplete Darwin process identity")
    path = ctypes.create_string_buffer(4096)
    check(library.proc_pidpath(pid, path, len(path)) > 0, "process executable unavailable")
    check(info.pid == pid, "process identity names another PID")
    return ProcessIdentity(
        pid,
        info.ppid,
        info.pgid,
        (info.start_seconds, info.start_microseconds),
        os.path.realpath(os.fsdecode(path.value)),
    )


def direct_children(parent: int) -> list[ProcessIdentity]:
    library = _libproc()
    size = library.proc_listpids(6, parent, None, 0)  # PROC_PPID_ONLY
    check(0 <= size <= 2 * 1024 * 1024, "process inventory unavailable or exceeds limit")
    capacity = size + 64
    pids = (ctypes.c_int32 * (capacity // ctypes.sizeof(ctypes.c_int32)))()
    measured = library.proc_listpids(6, parent, pids, capacity)
    check(0 <= measured < capacity, "process inventory changed beyond capacity")
    children = []
    for pid in pids[: measured // ctypes.sizeof(ctypes.c_int32)]:
        if pid > 0:
            identity = process_identity(pid)
            check(identity is not None, "broker child disappeared during inventory")
            children.append(identity)
    return children


def select_consumer(
    owner: ProcessIdentity, children: list[ProcessIdentity], expected: Path
) -> ProcessIdentity:
    check(len(children) == 2, "broker must own one guardian and one consumer")
    check(all(child.parent == owner.pid for child in children), "unexpected consumer parent")
    guardians = [
        child
        for child in children
        if child.executable == owner.executable and child.group == child.pid
    ]
    check(len(guardians) == 1, "missing or ambiguous owned guardian")
    guardian = guardians[0]
    consumers = [
        child
        for child in children
        if child.pid != guardian.pid
        and child.executable == str(expected.resolve())
        and child.group == guardian.pid
    ]
    check(len(consumers) == 1, "consumer executable or guardian group mismatch")
    return consumers[0]


def consumer_identity(
    broker: subprocess.Popen, owner: ProcessIdentity, expected: Path
) -> ProcessIdentity:
    # No broker RPC runs during inspection. The broker retains both direct
    # children; birth revalidation also refuses a changed snapshot. Observed
    # descendant PIDs are evidence only and are never used to send signals.
    check(broker.poll() is None, "owned broker exited")
    check(process_identity(broker.pid) == owner, "owned broker identity changed")
    consumer = select_consumer(owner, direct_children(owner.pid), expected)
    check(
        process_identity(consumer.pid) == consumer, "consumer identity changed during observation"
    )
    return consumer


def wait_for_consumer_exit(consumer: ProcessIdentity, timeout: float = 10) -> None:
    deadline = time.monotonic() + timeout
    while process_identity(consumer.pid) == consumer:
        check(time.monotonic() < deadline, "fixture consumer did not exit")
        time.sleep(SOCKET_POLL_SECONDS)


def crash_capable_source(source: str, request: Path) -> str:
    entry = "    static func main() async {"
    check(source.count(entry) == 1, "consumer main injection point absent or ambiguous")
    # Only the private copied fixture reads this unguessable, one-use capability.
    # The consumer exits itself; the controller never signals a discovered PID.
    injected = (
        entry
        + "\n"
        + """
        Task.detached {
            let request = URL(fileURLWithPath: REQUEST_PATH)
            while !Task.isCancelled {
                if FileManager.default.fileExists(atPath: request.path) {
                    do { try FileManager.default.removeItem(at: request); _exit(86) }
                    catch { return }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
""".replace("REQUEST_PATH", json.dumps(str(request), ensure_ascii=False))
    )
    return "import Darwin\nimport Foundation\n" + source.replace(entry, injected)


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
        crash_request = copied / ".verdictui" / ("reload-crash-" + uuid.uuid4().hex)
        original = crash_capable_source(source.read_text(), crash_request)
        source.write_text(original)
        fault = original.replace("faulty ? 6 : 96", "faulty ? 6 : 6").replace(
            "faulty ? 6 : 32", "faulty ? 6 : 6"
        )
        check(original != fault, "source change control absent")
        built = subprocess.run(
            [str(launcher), "list"], cwd=copied, capture_output=True, text=True, timeout=600
        )
        check(built.returncode == 0 and "consumer-settings" in built.stdout, built.stderr)

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
                expected = copied / ".build/debug/ConsumerScenarios"

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
                    owner = process_identity(broker.pid)
                    if owner is None or owner.executable != str(launcher.resolve()):
                        raise AssertionError("owned broker executable unavailable")
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
                            time.sleep(SOCKET_POLL_SECONDS)
                        check(Path(public_socket).exists(), "broker daemon not ready")
                    check(verify() == "PASS", f"{mode} initial consumer")
                    first_child = consumer_identity(broker, owner, expected)
                    source.write_text(fault)
                    check(verify() == "FAIL", f"{mode} did not rebuild changed source")
                    check(
                        consumer_identity(broker, owner, expected) != first_child,
                        "transport did not remain alive",
                    )
                    current_child = consumer_identity(broker, owner, expected)
                    crash_request.touch(exist_ok=False)
                    wait_for_consumer_exit(current_child)
                    check(verify() is None, "dead child masqueraded as available")
                    check(verify() == "FAIL", "next request did not recover")
                    source.write_text(original + "\nthis is invalid Swift !!!\n")
                    check(
                        verify() is None and broker.poll() is None,
                        "failed compile served stale verdict or killed broker",
                    )
                    source.write_text(original)
                    check(verify() == "PASS", "fixed source failed to recover")
                    print(
                        json.dumps(
                            {
                                "mode": mode,
                                "broker_pid": owner.pid,
                                "broker_birth": owner.birth,
                                "initial_consumer_pid": first_child.pid,
                                "crashed_consumer_pid": current_child.pid,
                                "recovered_consumer_pid": consumer_identity(
                                    broker, owner, expected
                                ).pid,
                                "verified": [
                                    "source rebuild",
                                    "owned crash",
                                    "failed build refusal",
                                    "recovery",
                                ],
                            },
                            sort_keys=True,
                        ),
                        flush=True,
                    )
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
            "consumer reload PASS: same MCP/daemon identity, rebuilt state, owned child crash recovery, failed-build refusal"
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
