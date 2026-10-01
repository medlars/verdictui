#!/usr/bin/env python3.14
"""Drive the real packaged WKWebView app; no mock bridge or global app state."""

from __future__ import annotations

import argparse
import ctypes
import errno
import importlib.util
import json
import math
import os
import signal
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from contextlib import ExitStack, contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit

# Loaded BY PATH (tests, `workbench_coverage.py`, the PM smoke stage), which does
# not put `scripts/` on `sys.path`, so the sibling below must be made resolvable.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from workbench_acceptance_receipts import (  # noqa: E402 — must follow the sys.path setup
    REQUIRED_IMAGES,  # noqa: F401 — read as `module.REQUIRED_IMAGES` by the test suite
    REQUIRED_PHASES,
    artifact,
    artifact_bytes,
    assess_motion,
    digest,
    same_json,
    validate_motion_phase,  # noqa: F401 — read as `module.validate_motion_phase` by the test suite
    validate_native_receipt,
)

WORKBENCH_NATIVE_TIMEOUT = 40
_STARTED = time.monotonic()


def phase_timing(phase: str) -> None:
    # Fixed phase names only: no project paths, URLs or application contents.
    print(
        f"WORKBENCH PHASE {phase} elapsed={time.monotonic() - _STARTED:.3f}s monotonic_ns={time.monotonic_ns()}",
        file=sys.stderr,
        flush=True,
    )


class LoopbackFixtureServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer's implementation performs unbounded reverse DNS. This
        # private numeric loopback fixture needs neither a hostname nor DNS.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


def create_output(path: Path) -> Path:
    if not path.is_absolute() or path.exists() or path.is_symlink():
        raise ValueError("output must be a new absolute private directory")
    parent = path.parent.resolve(strict=True)
    target = parent / path.name
    try:
        target.mkdir(mode=0o700)
    except OSError as error:
        raise ValueError("output directory is unavailable") from error
    return target


def save(path: Path, value: Any) -> None:
    with path.open("x", encoding="utf-8") as stream:
        os.chmod(path, 0o600)
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)


def load_identity(root: Path):
    path = root / "scripts/workbench_identity.py"
    if not path.is_file():
        raise ValueError("canonical workbench identity reader is unavailable")
    spec = importlib.util.spec_from_file_location("workbench_identity", path)
    if not spec or not spec.loader:
        raise ValueError("canonical workbench identity reader could not load")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def spawn_owned(arguments, **options) -> subprocess.Popen:
    if "start_new_session" in options:
        raise ValueError("process ownership controls session creation")
    process = subprocess.Popen(arguments, start_new_session=True, **options)
    # Popen's successful exec handshake guarantees setsid completed. Darwin's
    # getpgid/getsid stop resolving an exited zombie, so retain this launch fact.
    # Popen does not declare this private metadata attribute in its type contract.
    setattr(process, "_verdictui_owned_session", process.pid)  # noqa: B010
    return process


def owned_status(process: subprocess.Popen) -> int | None:
    """Observe without reaping: the retained child anchors its process group."""
    if process.returncode is not None:
        raise ValueError("process ownership already released")
    if getattr(process, "_verdictui_owned_session", None) != process.pid:
        raise ValueError("process ownership requires a dedicated session and group")
    try:
        observed = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    except ChildProcessError as error:
        raise ValueError("process ownership lost before cleanup") from error
    if observed is None:
        return None
    return observed.si_status if observed.si_code == os.CLD_EXITED else -observed.si_status


def group_running(process: subprocess.Popen) -> bool:
    """Darwin group inventory mirrors OwnedCommandProcess's zombie check."""
    owned_status(process)
    if sys.platform != "darwin":
        # Other platforms still receive TERM/KILL while the anchor is retained;
        # wait the bounded grace rather than infer descendant death from a leader.
        return True
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    members = (ctypes.c_int * 4096)()
    ctypes.set_errno(0)
    count = library.proc_listpids(2, process.pid, members, ctypes.sizeof(members))
    if count < 0 or (count == 0 and ctypes.get_errno()) or count >= ctypes.sizeof(members):
        raise ValueError("owned process group inventory unavailable or oversized")
    for pid in members[: count // ctypes.sizeof(ctypes.c_int)]:
        if pid <= 0:
            continue
        # Public proc_bsdshortinfo: pid, ppid, pgid, status, comm[16], eight uint32s.
        info = (ctypes.c_uint32 * 16)()
        ctypes.set_errno(0)
        read = library.proc_pidinfo(pid, 13, 0, info, ctypes.sizeof(info))
        if read == 0 and ctypes.get_errno() == errno.ESRCH:
            continue
        if read != ctypes.sizeof(info):
            raise ValueError("owned process member status unavailable")
        if info[2] == process.pid and info[3] != 5:  # SZOMB
            return True
    return False


def signal_owned(process: subprocess.Popen, number: int) -> None:
    owned_status(process)
    try:
        os.killpg(process.pid, number)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Darwin returns EPERM for a group of zombies, including our anchor.
        if group_running(process):
            raise


def wait_owned(process: subprocess.Popen, timeout: float) -> int:
    deadline = time.monotonic() + timeout
    while (code := owned_status(process)) is None:
        if time.monotonic() >= deadline:
            raise subprocess.TimeoutExpired(process.args, timeout)
        time.sleep(0.02)
    return code


def stop_owned(process: subprocess.Popen, grace: float = 6) -> None:
    phase_timing("cleanup-start")
    signal_owned(process, signal.SIGTERM)
    deadline = time.monotonic() + grace
    while group_running(process) and time.monotonic() < deadline:
        time.sleep(0.02)
    signal_owned(process, signal.SIGKILL)
    deadline = time.monotonic() + 2
    while sys.platform == "darwin" and group_running(process):
        if time.monotonic() >= deadline:
            raise ValueError("owned process group survived bounded cleanup")
        time.sleep(0.02)
    wait_owned(process, 2)
    process.wait(timeout=2)  # Release identity only after the final group signal.
    phase_timing("cleanup-end")


def run_owned_command(
    arguments: list[str], *, cwd: Path, timeout: float, cleanup_grace: float = 10
) -> subprocess.CompletedProcess[str]:
    """Outer PM/CI deadline permits the wrapper's detached-native cleanup."""
    phase_timing("outer-start")
    if not math.isfinite(timeout) or timeout <= 0 or not 0 <= cleanup_grace <= 15:
        raise ValueError("invalid native wrapper time limits")
    with (
        TerminationGuard() as guard,
        ExitStack() as cleanup,
        tempfile.TemporaryFile() as output,
        tempfile.TemporaryFile() as errors,
    ):
        with guard.registration():
            process = spawn_owned(arguments, cwd=cwd, stdout=output, stderr=errors)
            cleanup.callback(stop_owned, process, grace=cleanup_grace)
        try:
            deadline = time.monotonic() + timeout
            while (code := owned_status(process)) is None:
                if (
                    max(os.fstat(stream.fileno()).st_size for stream in (output, errors))
                    > 8 * 1024 * 1024
                ):
                    raise ValueError("native wrapper output exceeds budget")
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(arguments, timeout)
                time.sleep(0.02)
        finally:
            # Timeout/interrupt must deliver TERM, not subprocess.run's SIGKILL.
            guard.cleaning = True
            cleanup.close()
            if (
                max(os.fstat(stream.fileno()).st_size for stream in (output, errors))
                > 8 * 1024 * 1024
            ):
                raise ValueError("native wrapper output exceeds budget")
            for stream in (output, errors):
                stream.seek(0)
            stdout = output.read(8 * 1024 * 1024 + 1).decode("utf-8", errors="replace")
            stderr = errors.read(8 * 1024 * 1024 + 1).decode("utf-8", errors="replace")
            if stderr:
                print(stderr, file=sys.stderr, end="", flush=True)
            phase_timing("outer-end")
        return subprocess.CompletedProcess(arguments, code, stdout, stderr)


def native_resource_path(path: str) -> str:
    """Foundation reports Darwin's /private/var assets using the /var spelling."""
    if (
        sys.platform == "darwin"
        and path.startswith("/var/")
        and os.path.realpath("/var") == "/private/var"
    ):
        return "/private" + path
    # Do not resolve arbitrary aliases: build-tree fallback must still be refused.
    return path


def validate_report(report: dict, run_root: Path) -> dict:
    """Revalidate retained measurements without launching a process or UI."""
    validate_native_receipt(report, run_root)
    if report.get("driver_sha256") != digest(Path(__file__).resolve()):
        raise ValueError("acceptance wrapper identity differs")
    for key, expected, name in [
        ("layout_verdict", {"PASS", "FAIL"}, "workbench-connected-workflow"),
        ("negative_verdict", {"FAIL"}, "workbench-negative-control"),
    ]:
        verdict = json.loads(artifact_bytes(run_root, report.get(key)))
        if (
            not isinstance(verdict, dict)
            or verdict.get("status") not in expected
            or verdict.get("scenario") != name
            or not isinstance(verdict.get("findings"), list)
        ):
            raise ValueError("real browser judge outcome is missing or incorrect")
        if key == "negative_verdict" and not any(
            isinstance(finding, dict)
            and finding.get("severity") == "error"
            and finding.get("rule") in {"sibling-overlap", "content-overlap"}
            and str(finding.get("nodeID", "")).startswith("acceptance-negative-")
            for finding in verdict["findings"]
        ):
            raise ValueError("real DOM overlap negative control was not detected")
        errors = any(
            isinstance(item, dict) and item.get("severity") == "error"
            for item in verdict["findings"]
        )
        if errors != (verdict["status"] == "FAIL") or report[key].get("exit_code") != (
            1 if errors else 0
        ):
            raise ValueError("real browser verdict and exit code disagree")
    artifact(run_root, report.get("negative_tree"))
    native = json.loads(artifact_bytes(run_root, report.get("native_report")))
    validate_native_receipt(native, run_root)
    if any(not same_json(report.get(key), value) for key, value in native.items()):
        raise ValueError("retained native observations differ from the admitted report")
    if "motion_diagnostics" in native:
        if not same_json(report.get("motion_assessment"), assess_motion(native, run_root)):
            raise ValueError("motion assessment differs from actual native observations")
    elif "motion_assessment" in report or "motion_diagnostics" in report:
        # Legacy receipts remain inspectable but cannot carry a new unsupported claim.
        raise ValueError("motion assessment lacks native diagnostics")
    identities = report.get("identities", {})
    if not identities.get("app") or not identities.get("consumer"):
        raise ValueError("application and consumer identities are missing")
    loaded = report.get("loaded_page")
    resources = identities["app"].get("resource_root")
    if (
        not isinstance(loaded, str)
        or not isinstance(resources, str)
        or not Path(resources).is_absolute()
    ):
        raise ValueError("loaded page or packaged resource identity is missing")
    page = urlsplit(loaded)
    if (
        page.scheme != "file"
        or page.netloc
        or page.query
        or page.fragment
        or native_resource_path(unquote(page.path, errors="strict"))
        != native_resource_path(str(Path(resources) / "index.html"))
    ):
        raise ValueError("loaded page differs from the packaged resource identity")
    return report


class TerminationGuard:
    """Restore caller handlers; defer interruption until owned resources are registered."""

    def __init__(self):
        self.previous = {}
        self.pending = None
        self.deferred = False
        self.cleaning = False

    def interrupt(self, signum, _frame):
        if self.cleaning:
            return
        self.pending = signum
        if not self.deferred:
            self.check()

    def check(self):
        if self.pending is not None:
            self.cleaning = True
            raise ValueError(f"native acceptance interrupted by signal {self.pending}")

    @contextmanager
    def registration(self):
        self.deferred = True
        try:
            yield
        finally:
            self.deferred = False
            self.check()

    def __enter__(self):
        if threading.current_thread() is not threading.main_thread():
            raise ValueError("acceptance requires the main thread for owned-process cleanup")
        for signum in (signal.SIGTERM, signal.SIGINT):
            self.previous[signum] = signal.signal(signum, self.interrupt)
        return self

    def __exit__(self, *_error):
        for signum, handler in self.previous.items():
            signal.signal(signum, handler)


def run(args: argparse.Namespace, root: Path, output: Path) -> dict:
    with TerminationGuard() as guard, ExitStack() as cleanup:
        try:
            return _run(args, root, output, guard, cleanup)
        finally:
            guard.cleaning = True


def _run(args, root: Path, output: Path, guard: TerminationGuard, cleanup: ExitStack) -> dict:
    motion_host = getattr(args, "motion_host", "detached")
    if motion_host not in {"detached", "invisible-window"}:
        raise ValueError("invalid motion host mode")
    phase_timing("start")
    driver_sha256 = digest(Path(__file__).resolve())
    identity = load_identity(root)
    app_identity = identity.validate_app(root, args.app)
    phase_timing("app-identity")
    consumer_identity = identity.validate_consumer(
        root, args.consumer_runner, args.consumer_build_receipt
    )
    phase_timing("consumer-identity")
    release = threading.Event()
    token = uuid.uuid4().hex

    class Fixture(BaseHTTPRequestHandler):
        def log_message(self, _format, *values):
            pass

        def do_GET(self):
            if self.path != "/" + token:
                self.send_error(404)
                return
            marker = output / "fixture-request.json"
            try:
                save(marker, {"path": self.path, "received_at": time.time()})
            except FileExistsError:
                pass
            release.wait(args.timeout_seconds)
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.end_headers()
                self.wfile.write(
                    b"<!doctype html><title>Owned acceptance fixture</title><p>Controlled navigation</p>"
                )
            except BrokenPipeError, ConnectionResetError:
                pass

    with guard.registration():
        phase_timing("fixture-bind-start")
        server = LoopbackFixtureServer(("127.0.0.1", 0), Fixture)
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        cleanup.callback(thread.join, timeout=2)
        cleanup.callback(server.server_close)
        cleanup.callback(server.shutdown)
        cleanup.callback(release.set)
    phase_timing("fixture-ready")
    projects = []
    for name in ("consumer-a", "consumer-b"):
        project = output / name
        (project / ".verdictui").mkdir(parents=True, mode=0o700)
        save(project / ".verdictui/config.json", {"runner": str(args.consumer_runner)})
        save(
            project / ".verdictui/checks.json",
            {
                "checks": [
                    {
                        "name": "Existing rendered view",
                        "kind": "web",
                        "runner": str(root / ".verdictui/run-workbench.py"),
                        "subject": "workbench-connected-workflow",
                    }
                    if name == "consumer-b"
                    else {
                        "name": "Consumer scenario",
                        "kind": "scenario",
                        "scenario": "consumer-settings",
                    }
                ]
            },
        )
        projects.append(project)
    temporary = output / "temporary"
    temporary.mkdir(mode=0o700)
    run_id = str(uuid.uuid4())
    config = output / "config.json"
    save(
        config,
        {
            "schema": 1,
            "run_id": run_id,
            "output_root": str(output),
            "project_a": str(projects[0]),
            "project_b": str(projects[1]),
            "fixture_url": f"http://127.0.0.1:{server.server_port}/{token}",
            "timeout_seconds": args.timeout_seconds - 2,
            "motion_host": motion_host,
        },
    )
    executable = args.app / "Contents/MacOS/VerdictUIWorkbench"
    phase_timing("config-ready")
    process = None
    started = time.monotonic()
    with (output / "native.log").open("x") as log:
        os.chmod(output / "native.log", 0o600)
        with guard.registration():
            process = spawn_owned(
                [str(executable), "--acceptance-config", str(config)],
                cwd=root,
                env=dict(os.environ, TMPDIR=str(temporary)),
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            cleanup.callback(stop_owned, process)
        phase_timing("native-spawn")
        try:
            code = wait_owned(process, args.timeout_seconds)
        except subprocess.TimeoutExpired as error:
            raise ValueError("native acceptance exceeded its explicit deadline") from error
    phase_timing("native-end")
    if code:
        raise ValueError(f"native acceptance unavailable (exit {code}); inspect private native.log")
    native_path = output / "native-report.json"
    native = validate_native_receipt(json.loads(native_path.read_text()), output)
    if native.get("motion_diagnostics", {}).get("host_mode") != motion_host:
        raise ValueError("requested motion host was not observed")
    if native.get("run_id") != run_id:
        raise ValueError("native receipt belongs to another attempt")
    verdicts = {}
    for key, tree_key, name, expected_codes in [
        ("layout_verdict", "final_tree", "workbench-connected-workflow", {0, 1}),
        ("negative_verdict", "negative_tree", "workbench-negative-control", {1}),
    ]:
        result = subprocess.run(
            [
                str(args.app / "Contents/Helpers/verdictui"),
                "judge",
                str(artifact(output, native.get(tree_key))),
                "--web",
                "--name",
                name,
            ],
            capture_output=True,
            timeout=3,
            check=False,
        )
        if len(result.stdout) > 32 * 1024 * 1024:
            raise ValueError("actual browser judge exceeded its artifact budget")
        path = output / (key + ".json")
        try:
            verdict = json.loads(result.stdout)
        except ValueError as error:
            save(
                output / (key + "-unavailable.json"),
                {
                    "exit_code": result.returncode,
                    "stderr": result.stderr[:16384].decode("utf-8", errors="replace"),
                },
            )
            raise ValueError("actual browser judge produced no readable verdict") from error
        save(path, verdict)
        if result.returncode not in expected_codes:
            raise ValueError(
                f"actual browser judge did not produce the expected {key}; exit {result.returncode}; inspect {path.name}"
            )
        verdicts[key] = {"path": path.name, "sha256": digest(path), "exit_code": result.returncode}
        phase_timing(key)
    if (
        identity.validate_app(root, args.app) != app_identity
        or identity.validate_consumer(root, args.consumer_runner, args.consumer_build_receipt)
        != consumer_identity
    ):
        raise ValueError("source or executable identity changed during acceptance")
    phase_timing("postflight-identities")
    if digest(Path(__file__).resolve()) != driver_sha256:
        raise ValueError("acceptance wrapper changed during the attempt")
    report = dict(
        native,
        **verdicts,
        driver_sha256=driver_sha256,
        identities={"app": app_identity, "consumer": consumer_identity},
        native_report={"path": native_path.name, "sha256": digest(native_path)},
        elapsed_seconds=time.monotonic() - started,
        owned_process={"pid": process.pid, "returncode": code},
    )
    if "motion_diagnostics" in native:
        report["motion_assessment"] = assess_motion(native, output)
    validated_report = validate_report(report, output)
    phase_timing("end")
    return validated_report


def main() -> int:
    phase_timing("main")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--consumer-runner", type=Path, required=True)
    parser.add_argument("--consumer-build-receipt", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=float, default=25)
    parser.add_argument(
        "--motion-host", choices=("detached", "invisible-window"), default="detached"
    )
    args = parser.parse_args()
    output = None
    try:
        if not 5 <= args.timeout_seconds <= 300:
            raise ValueError("timeout must be between 5 and 300 seconds")
        output = create_output(args.output)
        args.app = args.app.resolve(strict=True)
        args.consumer_runner = args.consumer_runner.resolve(strict=True)
        args.consumer_build_receipt = args.consumer_build_receipt.resolve(strict=True)
        report = run(args, Path(__file__).resolve().parents[1], output)
        save(output / "report.json", report)
        status = json.loads(artifact_bytes(output, report["layout_verdict"]))["status"]
        print(
            f"WORKBENCH ACCEPTANCE {status}: {report['assertions']} assertions, {len(REQUIRED_PHASES)}/{len(REQUIRED_PHASES)} native phases complete"
        )
        return 0 if status == "PASS" else 1
    except (OSError, ValueError, ImportError, subprocess.SubprocessError) as error:
        if output and not (output / "report.json").exists():
            save(
                output / "report.json", {"schema": 1, "status": "unavailable", "error": str(error)}
            )
        print(f"WORKBENCH ACCEPTANCE UNAVAILABLE: {error}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
