#!/usr/bin/env python3.14
"""Drive the real packaged WKWebView app; no mock bridge or global app state."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import math
import os
import signal
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, cast

REQUIRED_PHASES = (
    "connected",
    "project-selection",
    "edit-save",
    "consumer-pass",
    "consumer-fail",
    "running-motion",
    "cancellation",
    "history",
    "reload",
    "geometry",
)
REQUIRED_IMAGES = {
    "connected",
    "pass",
    "fail",
    "running-before",
    "running-after",
    "history",
    "final",
    "compact",
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


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


def artifact(root: Path, descriptor: Any) -> Path:
    if not isinstance(descriptor, dict):
        raise ValueError("artifact descriptor missing")
    name, expected = descriptor.get("path"), descriptor.get("sha256")
    if not isinstance(name, str) or Path(name).name != name or not name:
        raise ValueError("artifact escapes the owned output directory")
    path = root / name
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError("artifact is missing, linked, or oversized")
    if not isinstance(expected, str) or digest(path) != expected:
        raise ValueError("artifact content hash differs")
    return path


def artifact_bytes(root: Path, descriptor: Any) -> bytes:
    path = artifact(root, descriptor)
    descriptor_fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor_fd, "rb") as stream:
        body = stream.read(32 * 1024 * 1024 + 1)
    if len(body) > 32 * 1024 * 1024 or hashlib.sha256(body).hexdigest() != descriptor["sha256"]:
        raise ValueError("artifact changed before decoding")
    return body


def validate_native_receipt(receipt: Any, root: Path) -> dict:
    if (
        not isinstance(receipt, dict)
        or receipt.get("schema") != 1
        or receipt.get("status") != "pass"
    ):
        raise ValueError("native acceptance is not a complete pass")
    phases = receipt.get("phases")
    if not isinstance(phases, list) or [p.get("id") for p in phases if isinstance(p, dict)] != list(
        REQUIRED_PHASES
    ):
        raise ValueError("required native workflow phases missing or duplicated")
    if receipt.get("required_phase_ids") != list(REQUIRED_PHASES) or any(
        p.get("status") != "pass" for p in phases
    ):
        raise ValueError("native phase contract differs")
    if not isinstance(receipt.get("assertions"), int) or receipt["assertions"] < len(
        REQUIRED_PHASES
    ):
        raise ValueError("native acceptance contains too few observations")
    cleanup = receipt.get("cleanup", {})
    if (
        not isinstance(cleanup, dict)
        or cleanup.get("bridge_shutdown_awaited") is not True
        or cleanup.get("visible_windows") != 0
    ):
        raise ValueError("native cleanup or quiet-window assertion missing")
    snapshots = receipt.get("snapshots")
    if (
        not isinstance(snapshots, list)
        or not all(isinstance(s, dict) for s in snapshots)
        or {s.get("phase") for s in snapshots} != REQUIRED_IMAGES
        or len(snapshots) != len(REQUIRED_IMAGES)
    ):
        raise ValueError("required native PNG phases missing")
    from PIL import Image

    for image in snapshots:
        with Image.open(io.BytesIO(artifact_bytes(root, image))) as decoded:
            if decoded.format != "PNG" or decoded.size != (image.get("width"), image.get("height")):
                raise ValueError("snapshot PNG dimensions differ")
            decoded.load()
            if decoded.width < 760 or decoded.height < 600:
                raise ValueError("snapshot viewport is incomplete")
            extrema = cast(tuple[tuple[int, int], ...], decoded.convert("RGB").getextrema())
            if all(lo == hi for lo, hi in extrema):
                raise ValueError("snapshot is blank")
    history = json.loads(artifact_bytes(root, receipt.get("history")))
    if not isinstance(history, dict):
        raise ValueError("persisted history is malformed")
    entries = history.get("history", [])
    if not isinstance(entries, list) or not all(isinstance(entry, dict) for entry in entries):
        raise ValueError("persisted history is malformed")
    if [entry.get("status") for entry in entries] != ["unavailable", "fail", "pass"]:
        raise ValueError("real persisted history does not contain required outcomes")
    for entry, expected in zip(entries[1:], ["consumer-fault", "consumer-settings"], strict=True):
        checks = entry.get("report", {}).get("checks", [])
        if len(checks) != 1 or checks[0].get("verdict", {}).get("scenario") != expected:
            raise ValueError("consumer result identity differs")
    tree = json.loads(artifact_bytes(root, receipt.get("final_tree")))
    count = 0
    identifiers = set()
    stack = [(tree, 0)]
    while stack:
        node, depth = stack.pop()
        count += 1
        if not isinstance(node, dict) or count > 10_000 or depth > 100:
            raise ValueError("observed DOM tree exceeds its bounded shape")
        attributes = node.get("attributes", {})
        if not isinstance(attributes, dict) or attributes.get("web.observer") != "WKWebView DOM":
            raise ValueError("tree lacks its actual DOM observation source")
        frame = node.get("frame")
        children = node.get("children")
        if (
            not isinstance(node.get("id"), str)
            or not isinstance(node.get("role"), str)
            or not node["role"]
            or not isinstance(children, list)
            or not isinstance(frame, dict)
        ):
            raise ValueError("DOM node has an invalid shape")
        if (
            any(
                type(frame.get(key)) not in (int, float) or not math.isfinite(frame[key])
                for key in ("x", "y", "width", "height")
            )
            or frame["width"] < 0
            or frame["height"] < 0
        ):
            raise ValueError("DOM frame is nonfinite or invalid")
        if node.get("id"):
            if node["id"] in identifiers:
                raise ValueError("DOM IDs are duplicated")
            identifiers.add(node["id"])
        stack.extend((child, depth + 1) for child in children)
    if count < 10 or not {"run-checks", "verification-stage", "project-name"}.issubset(identifiers):
        raise ValueError("observed DOM tree is incomplete")
    return receipt


def stop_owned(process: subprocess.Popen, grace: float = 2) -> None:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=grace)


def validate_report(report: dict, run_root: Path) -> dict:
    """Revalidate retained measurements without launching a process or UI."""
    validate_native_receipt(report, run_root)
    native = json.loads(artifact_bytes(run_root, report.get("native_report")))
    validate_native_receipt(native, run_root)
    if any(report.get(key) != value for key, value in native.items()):
        raise ValueError("retained native observations differ from the admitted report")
    identities = report.get("identities", {})
    if not identities.get("app") or not identities.get("consumer"):
        raise ValueError("application and consumer identities are missing")
    return report


def run(args: argparse.Namespace, root: Path, output: Path) -> dict:
    identity = load_identity(root)
    app_identity = identity.validate_app(root, args.app)
    consumer_identity = identity.validate_consumer(
        root, args.consumer_runner, args.consumer_build_receipt
    )
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

    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
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
        },
    )
    executable = args.app / "Contents/MacOS/VerdictUIWorkbench"
    process = None
    started = time.monotonic()
    try:
        with (output / "native.log").open("x") as log:
            os.chmod(output / "native.log", 0o600)
            process = subprocess.Popen(
                [str(executable), "--acceptance-config", str(config)],
                cwd=root,
                env=dict(os.environ, TMPDIR=str(temporary)),
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                code = process.wait(timeout=args.timeout_seconds)
            except subprocess.TimeoutExpired as error:
                raise ValueError("native acceptance exceeded its explicit deadline") from error
        if code:
            raise ValueError(
                f"native acceptance unavailable (exit {code}); inspect private native.log"
            )
        native_path = output / "native-report.json"
        native = validate_native_receipt(json.loads(native_path.read_text()), output)
        if native.get("run_id") != run_id:
            raise ValueError("native receipt belongs to another attempt")
        if (
            identity.validate_app(root, args.app) != app_identity
            or identity.validate_consumer(root, args.consumer_runner, args.consumer_build_receipt)
            != consumer_identity
        ):
            raise ValueError("source or executable identity changed during acceptance")
        report = dict(
            native,
            identities={"app": app_identity, "consumer": consumer_identity},
            native_report={"path": native_path.name, "sha256": digest(native_path)},
            elapsed_seconds=time.monotonic() - started,
            owned_process={"pid": process.pid, "returncode": code},
        )
        return validate_report(report, output)
    finally:
        if process:
            stop_owned(process)
        release.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--consumer-runner", type=Path, required=True)
    parser.add_argument("--consumer-build-receipt", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=float, default=25)
    args = parser.parse_args()
    output = None
    try:
        if not 5 <= args.timeout_seconds <= 300:
            raise ValueError("timeout must be between5 and300 seconds")
        output = create_output(args.output)
        args.app = args.app.resolve(strict=True)
        args.consumer_runner = args.consumer_runner.resolve(strict=True)
        args.consumer_build_receipt = args.consumer_build_receipt.resolve(strict=True)
        report = run(args, Path(__file__).resolve().parents[1], output)
        save(output / "report.json", report)
        print(
            f"WORKBENCH ACCEPTANCE PASS: {report['assertions']} assertions, {len(REQUIRED_PHASES)}/{len(REQUIRED_PHASES)} native phases complete"
        )
        return 0
    except (OSError, ValueError, ImportError, subprocess.SubprocessError) as error:
        if output and not (output / "report.json").exists():
            save(
                output / "report.json", {"schema": 1, "status": "unavailable", "error": str(error)}
            )
        print(f"WORKBENCH ACCEPTANCE UNAVAILABLE: {error}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
