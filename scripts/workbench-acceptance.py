#!/usr/bin/env python3.14
"""Drive the real packaged WKWebView app; no mock bridge or global app state."""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import importlib.util
import io
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
from typing import Any, cast
from urllib.parse import unquote, urlsplit

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
    "web-renderer",
    "connected",
    "pass",
    "fail",
    "running-before",
    "running-after",
    "history",
    "final",
    "compact",
}

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


def validate_web_editor(observations: Any) -> None:
    if not isinstance(observations, dict):
        raise ValueError("web editor roundtrip observations missing")
    original = observations.get("renderer_original", {})
    expected = {**original, "name": "Saved rendered view"} if isinstance(original, dict) else {}
    url = observations.get("url_mode", {})
    if (
        not isinstance(original, dict)
        or set(original) != {"name", "kind", "runner", "subject"}
        or original.get("kind") != "web"
        or not all(isinstance(value, str) and value.strip() for value in original.values())
        or observations.get("renderer_renamed") != expected
        or observations.get("renderer_restored") != expected
        or not isinstance(url, dict)
        or set(url) != {"name", "kind", "url", "expectText"}
        or url.get("name") != expected["name"]
        or url.get("kind") != "web"
        or not isinstance(url.get("url"), str)
        or not url["url"].startswith("http://127.0.0.1:")
        or url.get("expectText") != "Controlled navigation"
    ):
        raise ValueError("web editor roundtrip did not preserve exclusive declarations")


def validate_motion_phase(observed: Any) -> None:
    if not isinstance(observed, dict) or any(
        type(observed.get(key)) is not bool
        for key in ("reduced_motion", "normal_motion_verified", "os_reduced_motion")
    ):
        raise ValueError("actual motion media observations missing")
    if observed["normal_motion_verified"] != (not observed["reduced_motion"]):
        raise ValueError("motion mode claim differs from media observation")
    timelines = []
    for key in ("before", "after"):
        if not isinstance(observed.get(key), str):
            raise ValueError("actual motion timeline missing")
        timeline = json.loads(observed[key])
        if not isinstance(timeline, list) or any(
            not isinstance(item, dict)
            or type(item.get("time")) not in (int, float)
            or not math.isfinite(item["time"])
            or item.get("state") not in {"idle", "running", "paused", "finished"}
            for item in timeline
        ):
            raise ValueError("actual motion timeline malformed")
        timelines.append(timeline)
    if observed["reduced_motion"]:
        if any(timelines):
            raise ValueError("reduced motion retained animation")
    elif not any(
        first["state"] == second["state"] == "running" and second["time"] > first["time"]
        for first, second in zip(*timelines, strict=False)
    ):
        raise ValueError("normal native motion did not advance")


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
    editor = phases[2].get("observations")
    validate_web_editor(editor.get("web_editor") if isinstance(editor, dict) else None)
    validate_motion_phase(phases[5].get("observations"))
    if "motion_diagnostics" in receipt:
        assess_motion(receipt, root)
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


def same_json(left: Any, right: Any) -> bool:
    """JSON numbers may change int/float representation, but booleans never alias them."""
    if type(left) in (int, float) and type(right) in (int, float):
        return math.isfinite(left) and math.isfinite(right) and left == right
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(same_json(left[key], right[key]) for key in left)
    if isinstance(left, list):
        return len(left) == len(right) and all(
            same_json(a, b) for a, b in zip(left, right, strict=True)
        )
    return left == right


def assess_motion(receipt: dict, root: Path) -> dict:
    """Admit sampled telemetry; never turn a reduced/unknown observation into normal."""
    diagnostic = receipt.get("motion_diagnostics")
    if not isinstance(diagnostic, dict) or diagnostic.get("schema") != 1:
        raise ValueError("motion diagnostics missing")
    mode = diagnostic.get("host_mode")
    if mode not in {"detached", "invisible-window"}:
        raise ValueError("motion host mode unavailable")

    def finite(value):
        return type(value) in (int, float) and math.isfinite(value)

    def cursor(value):
        return (
            isinstance(value, dict)
            and set(value) == {"x", "y"}
            and all(finite(value[key]) for key in ("x", "y"))
        )

    def native(value):
        if not isinstance(value, dict) or not finite(value.get("uptime_seconds")):
            raise ValueError("motion native timestamp missing")
        if not cursor(value.get("cursor")) or type(value.get("frontmost_pid")) is not int:
            raise ValueError("motion native interference observations missing")
        if any(
            type(value.get(key)) is not bool
            for key in (
                "os_reduced_motion",
                "view_has_window",
                "view_window_visible",
                "view_window_key",
            )
        ) or any(
            type(value.get(key)) is not int or value[key] < 0
            for key in ("visible_windows", "key_windows")
        ):
            raise ValueError("motion native boolean/window observation malformed")
        return value

    samples = diagnostic.get("samples")
    checkpoints = ["page-ready", "running-before", "running-after", "recreated-page-ready"]
    if (
        not isinstance(samples, list)
        or len(samples) != 4
        or any(
            not isinstance(sample, dict) or sample.get("checkpoint") != checkpoint
            for sample, checkpoint in zip(samples, checkpoints, strict=True)
        )
    ):
        raise ValueError("motion checkpoints incomplete")
    readings = []
    last = -math.inf
    for sample in samples:
        before, after = native(sample.get("native_before")), native(sample.get("native_after"))
        if not last <= before["uptime_seconds"] <= after["uptime_seconds"]:
            raise ValueError("motion sample timing is inconsistent")
        last = after["uptime_seconds"]
        readings.extend([before, after])
        web = sample.get("web")
        if not isinstance(web, dict) or any(
            type(web.get(key)) is not bool for key in ("reduced", "no_preference", "hidden")
        ):
            raise ValueError("motion media boolean unavailable")
        if (
            not finite(web.get("at"))
            or web["at"] < 0
            or web.get("visibility") not in {"hidden", "visible"}
            or not isinstance(web.get("document_id"), str)
            or not web["document_id"]
        ):
            raise ValueError("motion web timestamp/visibility unavailable")
        animations = web.get("animations")
        if not isinstance(animations, list) or any(
            not isinstance(item, dict)
            or not isinstance(item.get("name"), str)
            or type(item.get("id")) is not int
            or item["id"] <= 0
            or item.get("state") not in {"idle", "running", "paused", "finished"}
            or (item.get("time") is not None and not finite(item["time"]))
            for item in animations
        ):
            raise ValueError("motion animation telemetry malformed")
        if len({item["id"] for item in animations}) != len(animations):
            raise ValueError("motion animation identities duplicated")
        changes = web.get("changes")
        if (
            not isinstance(changes, list)
            or len(changes) > 128
            or any(
                not isinstance(change, dict)
                or not finite(change.get("at"))
                or type(change.get("matches")) is not bool
                or not isinstance(change.get("media"), str)
                for change in changes
            )
            or type(web.get("changes_dropped")) is not int
            or web["changes_dropped"] < 0
        ):
            raise ValueError("motion change history malformed")
        raw = json.loads(artifact_bytes(root, sample.get("raw_artifact")))
        if (
            not isinstance(raw, dict)
            or any(
                not same_json(raw.get(key), sample[key])
                for key in ("checkpoint", "native_before", "native_after")
            )
            or not same_json(json.loads(raw.get("web_json", "")), web)
        ):
            raise ValueError("motion raw observation differs")
    final = native(diagnostic.get("final_native"))
    if (
        final["uptime_seconds"] < last
        or not cursor(diagnostic.get("initial_cursor"))
        or type(diagnostic.get("initial_frontmost_pid")) is not int
    ):
        raise ValueError("motion final/initial observations missing")
    changes = diagnostic.get("accessibility_changes")
    if not isinstance(changes, list) or len(changes) > 128:
        raise ValueError("motion accessibility change history missing")
    for change in changes:
        readings.append(native(change))
    dropped = diagnostic.get("accessibility_changes_dropped")
    names = diagnostic.get("environment_variable_names")
    if (
        type(dropped) is not int
        or dropped < 0
        or not isinstance(names, list)
        or not all(isinstance(name, str) and name for name in names)
        or names != sorted(set(names))
    ):
        raise ValueError("motion environment/history provenance malformed")
    quiet = diagnostic["initial_frontmost_pid"] > 0 and all(
        reading["frontmost_pid"] == diagnostic["initial_frontmost_pid"]
        and reading["cursor"] == diagnostic["initial_cursor"]
        and reading["visible_windows"] == reading["key_windows"] == 0
        and not reading["view_window_visible"]
        and not reading["view_window_key"]
        for reading in [*readings, final]
    )
    association = all(
        sample[side]["view_has_window"] == (mode == "invisible-window")
        for sample in samples
        for side in ("native_before", "native_after")
    )
    first, second = samples[1]["web"], samples[2]["web"]
    same_document = (
        samples[0]["web"]["document_id"] == first["document_id"] == second["document_id"]
        and samples[3]["web"]["document_id"] != first["document_id"]
        and samples[0]["web"]["at"] <= first["at"] < second["at"]
    )
    later = {item["id"]: item for item in second["animations"]}
    progressed = {
        a["name"]
        for a in first["animations"]
        if same_document
        and (b := later.get(a["id"])) is not None
        and a["name"] == b["name"]
        and a["state"] == b["state"] == "running"
        and finite(a["time"])
        and finite(b["time"])
        and b["time"] > a["time"]
    }
    observed = receipt["phases"][5].get("observations", {})
    if not isinstance(observed, dict):
        raise ValueError("motion phase observations missing")
    normal = (
        observed.get("normal_motion_verified") is True
        and observed.get("reduced_motion") is False
        and all(
            web["reduced"] is False
            and web["no_preference"] is True
            and web.get("stage") == "running"
            for web in (first, second)
        )
        and {"orbit", "breathe", "scan-light", "inspection-tilt"}.issubset(progressed)
        and quiet
        and association
        and dropped == 0
        and all(sample["web"]["changes_dropped"] == 0 for sample in samples)
    )
    return {
        "normal_css_timeline": "verified" if normal else "unavailable",
        "painted_motion": "unreviewed",
        "host_mode": mode,
        "sampled_noninterference": quiet,
        "host_association_observed": association,
        "same_document_clock_ordered": same_document,
        "progressed_animation_names": sorted(progressed),
        "media_os_agreement": all(
            sample["web"]["reduced"] == sample[side]["os_reduced_motion"]
            for sample in samples
            for side in ("native_before", "native_after")
        ),
        "limit": "CSS timeline evidence only; painted motion needs independent PNG comparison. Sampled observations do not exclude unobserved transient events; no preference override.",
    }


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
