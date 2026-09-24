"""Admission tests use labelled synthetic receipts; positive rendering is native."""

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
from typing import Any

import pytest
from PIL import Image

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/workbench-acceptance.py"


def subject():
    spec = importlib.util.spec_from_file_location("workbench_acceptance", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize("receipt", [{}, {"status": "pass"}, {"status": "pass", "phases": []}])
def test_missing_native_observations_never_pass(tmp_path, receipt):
    with pytest.raises(ValueError):
        subject().validate_native_receipt(receipt, tmp_path)


def test_missing_identity_reader_is_unavailable(tmp_path):
    with pytest.raises(ValueError, match="identity"):
        subject().load_identity(tmp_path)


def test_output_reuse_and_symlinks_are_refused(tmp_path):
    module = subject()
    existing = tmp_path / "existing"
    existing.mkdir()
    with pytest.raises(ValueError):
        module.create_output(existing)
    link = tmp_path / "link"
    link.symlink_to(existing, target_is_directory=True)
    with pytest.raises(ValueError):
        module.create_output(link)


def test_artifact_escape_is_refused(tmp_path):
    with pytest.raises(ValueError):
        subject().artifact(tmp_path, {"path": "../outside", "sha256": "0" * 64})


def synthetic_receipt(root) -> dict[str, Any]:
    """Synthetic validator unit data, never native/UI acceptance evidence."""
    module = subject()

    def descriptor(name, value):
        path = root / name
        path.write_text(json.dumps(value))
        return {"path": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}

    images = []
    for phase in sorted(module.REQUIRED_IMAGES):
        path = root / (phase + ".png")
        image = Image.new("RGB", (1160, 800), "white")
        image.putpixel((1, 1), (20, 40, 60))
        image.save(path)
        images.append(
            {
                "phase": phase,
                "path": path.name,
                "sha256": module.digest(path),
                "width": 1160,
                "height": 800,
                "viewport": {"width": 1160, "height": 800},
            }
        )
    identifiers = [
        "run-checks",
        "verification-stage",
        "project-name",
        *[f"unit-{n}" for n in range(7)],
    ]
    children = [
        {
            "id": key,
            "role": "button",
            "frame": {"x": n * 30, "y": 1, "width": 28, "height": 28},
            "isVisible": True,
            "attributes": {"web.observer": "WKWebView DOM"},
            "children": [],
        }
        for n, key in enumerate(identifiers)
    ]
    tree = {
        "id": "",
        "role": "container",
        "frame": {"x": 0, "y": 0, "width": 1160, "height": 800},
        "isVisible": True,
        "attributes": {"web.observer": "WKWebView DOM"},
        "children": children,
    }
    history = {
        "history": [
            {"status": status, "report": {"checks": [{"verdict": {"scenario": scenario}}]}}
            for status, scenario in [
                ("unavailable", None),
                ("fail", "consumer-fault"),
                ("pass", "consumer-settings"),
            ]
        ]
    }
    receipt = {
        "schema": 1,
        "status": "pass",
        "required_phase_ids": list(module.REQUIRED_PHASES),
        "phases": [
            {"id": name, "status": "pass", "observations": {}} for name in module.REQUIRED_PHASES
        ],
        "assertions": 20,
        "cleanup": {"bridge_shutdown_awaited": True, "visible_windows": 0},
        "snapshots": images,
        "history": descriptor("state.json", history),
        "final_tree": descriptor("final-tree.json", tree),
    }
    native = descriptor("native-report.json", receipt)
    return dict(
        receipt,
        native_report=native,
        identities={"app": {"test": True}, "consumer": {"test": True}},
    )


def test_complete_validator_unit_fixture_passes_without_launching(tmp_path, monkeypatch):
    module = subject()
    monkeypatch.setattr(
        module.subprocess,
        "Popen",
        lambda *_args, **_kwargs: pytest.fail("offline validation launched a process"),
    )
    receipt = synthetic_receipt(tmp_path)
    assert module.validate_report(receipt, tmp_path) is receipt


@pytest.mark.parametrize(
    "mutation", ["phase", "zero", "native", "png", "blank", "tree", "history", "cleanup", "symlink"]
)
def test_incomplete_or_tampered_evidence_is_rejected(tmp_path, mutation):
    receipt = synthetic_receipt(tmp_path)
    original = copy.deepcopy(receipt)
    if mutation == "phase":
        receipt["phases"].pop(5)  # Real running motion is mandatory.
    elif mutation == "zero":
        receipt["assertions"] = 0
    elif mutation == "native":
        receipt["phases"][0]["observations"] = {"forged": True}
    elif mutation == "png":
        (tmp_path / receipt["snapshots"][0]["path"]).write_bytes(b"not a PNG")
    elif mutation == "blank":
        image = receipt["snapshots"][0]
        Image.new("RGB", (1160, 800), "white").save(tmp_path / image["path"])
        image["sha256"] = subject().digest(tmp_path / image["path"])
    elif mutation == "tree":
        (tmp_path / "final-tree.json").write_text('{"children":[]}')
        receipt["final_tree"]["sha256"] = subject().digest(tmp_path / "final-tree.json")
    elif mutation == "history":
        (tmp_path / "state.json").write_text('{"history":[]}')
        receipt["history"]["sha256"] = subject().digest(tmp_path / "state.json")
    elif mutation == "cleanup":
        receipt["cleanup"]["bridge_shutdown_awaited"] = False
    elif mutation == "symlink":
        path = tmp_path / receipt["snapshots"][0]["path"]
        path.unlink()
        path.symlink_to(tmp_path / receipt["snapshots"][1]["path"])
        receipt["snapshots"][0]["sha256"] = receipt["snapshots"][1]["sha256"]
    assert receipt != original or mutation in {"png", "symlink"}
    with pytest.raises(ValueError):
        subject().validate_report(receipt, tmp_path)


def test_native_phase_guard_independently_rejects_missing_running_phase(tmp_path):
    receipt = synthetic_receipt(tmp_path)
    receipt["phases"].pop(5)
    with pytest.raises(ValueError, match="phases"):
        subject().validate_native_receipt(receipt, tmp_path)


def test_native_assertion_guard_independently_rejects_zero(tmp_path):
    receipt = synthetic_receipt(tmp_path)
    receipt["assertions"] = 0
    with pytest.raises(ValueError, match="observations"):
        subject().validate_native_receipt(receipt, tmp_path)


def test_native_image_guard_independently_rejects_missing_snapshot(tmp_path):
    receipt = synthetic_receipt(tmp_path)
    receipt["snapshots"].pop()
    with pytest.raises(ValueError, match="PNG phases"):
        subject().validate_native_receipt(receipt, tmp_path)


def test_artifact_hash_guard_checks_actual_bytes(tmp_path):
    path = tmp_path / "data.json"
    path.write_text('{"observed":true}')
    with pytest.raises(ValueError, match="hash"):
        subject().artifact(tmp_path, {"path": path.name, "sha256": "0" * 64})


def test_native_cleanup_guard_independently_rejects_visible_window(tmp_path):
    receipt = synthetic_receipt(tmp_path)
    receipt["cleanup"]["visible_windows"] = 1
    with pytest.raises(ValueError, match="quiet-window"):
        subject().validate_native_receipt(receipt, tmp_path)
