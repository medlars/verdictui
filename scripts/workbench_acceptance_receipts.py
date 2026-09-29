"""Receipt, artifact and motion validators for `workbench-acceptance.py`.

Pure checks over an owned output directory; no processes are spawned here. Split
out of the hyphen-named driver (CIS-67024614), which re-imports every name below
so `module.<name>` and the driver's own call sites keep resolving through it.
"""

from __future__ import annotations

import hashlib
import io
import json
import math
import os
from pathlib import Path
from typing import Any, cast

MAX_OBSERVED_TREE_NODES = 10_000
MAX_OBSERVED_TREE_DEPTH = 100
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


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


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
        if (
            not isinstance(node, dict)
            or count > MAX_OBSERVED_TREE_NODES
            or depth > MAX_OBSERVED_TREE_DEPTH
        ):
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
