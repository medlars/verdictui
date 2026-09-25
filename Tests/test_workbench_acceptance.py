"""Admission tests use labelled synthetic receipts; positive rendering is native."""

import copy
import hashlib
import importlib.util
import json
import sys
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


def test_exited_native_leader_still_closes_owned_descendant(tmp_path):
    import os
    import sys
    import time

    release = tmp_path / "release"
    stopped = tmp_path / "stopped"
    ready = tmp_path / "ready"
    script = (
        "import os,pathlib,signal,time\n"
        f"release=pathlib.Path({str(release)!r});stopped=pathlib.Path({str(stopped)!r})\n"
        "child=os.fork()\n"
        "if child:\n"
        " os._exit(7)\n"
        "def stop(sig,frame):\n"
        " stopped.write_text(str(sig));os._exit(0)\n"
        "signal.signal(signal.SIGTERM,stop)\n"
        f"pathlib.Path({str(ready)!r}).write_text(str(os.getpid()))\n"
        "deadline=time.monotonic()+10\n"
        "while not release.exists() and time.monotonic()<deadline: time.sleep(.01)\n"
    )
    module = subject()
    process = module.spawn_owned([sys.executable, "-c", script])
    try:
        deadline = time.monotonic() + 5
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert ready.exists()
        while os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
            assert time.monotonic() < deadline
            time.sleep(0.01)
        module.stop_owned(process, grace=0.3)
        assert stopped.exists(), "exited native leader left its owned descendant running"
        assert stopped.read_text() == "15"
    finally:
        release.touch()
        process.wait(timeout=3)


def test_reaped_native_leader_refuses_signals(monkeypatch):
    import subprocess
    import sys

    process = subprocess.Popen([sys.executable, "-c", "pass"], start_new_session=True)
    process.wait(timeout=5)
    monkeypatch.setattr("os.killpg", lambda *_: pytest.fail("signalled a reaped identity"))
    with pytest.raises(ValueError, match="ownership already released"):
        subject().stop_owned(process, grace=0)


def test_waitid_lost_ownership_refuses_signals(monkeypatch):
    import os
    import sys

    module = subject()
    process = module.spawn_owned([sys.executable, "-c", "pass"])
    os.waitpid(process.pid, 0)  # Another owner reaped it without updating Popen.
    monkeypatch.setattr("os.killpg", lambda *_: pytest.fail("signalled lost ownership"))
    with pytest.raises(ValueError, match="ownership lost"):
        module.stop_owned(process, grace=0)
    process.returncode = 0


def test_nonowned_group_refuses_signals(monkeypatch):
    import subprocess
    import sys

    process = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(5)"])
    try:
        monkeypatch.setattr("os.killpg", lambda *_: pytest.fail("signalled an unowned group"))
        with pytest.raises(ValueError, match="dedicated session"):
            subject().stop_owned(process, grace=0)
    finally:
        process.terminate()
        process.wait(timeout=3)


def test_loopback_fixture_never_resolves_a_hostname(monkeypatch):
    import socket
    from http.server import BaseHTTPRequestHandler

    monkeypatch.setattr(socket, "getfqdn", lambda *_: pytest.fail("loopback fixture performed DNS"))
    with subject().LoopbackFixtureServer(("127.0.0.1", 0), BaseHTTPRequestHandler) as server:
        assert server.server_name == "127.0.0.1"
        assert server.server_port > 0


def test_outer_signal_reaches_detached_native_and_restores_handler(tmp_path):
    import signal
    import subprocess
    import sys
    import time

    ready, stopped = tmp_path / "ready", tmp_path / "stopped"
    release, restored = tmp_path / "release", tmp_path / "restored"
    native = tmp_path / "native.py"
    native.write_text(
        "import pathlib,signal,time,sys\n"
        "def stop(sig,frame):\n"
        f" pathlib.Path({str(stopped)!r}).write_text(str(sig));sys.exit(0)\n"
        "signal.signal(signal.SIGTERM,stop)\n"
        f"pathlib.Path({str(ready)!r}).touch()\n"
        "deadline=time.monotonic()+10\n"
        f"while not pathlib.Path({str(release)!r}).exists() and time.monotonic()<deadline: time.sleep(.01)\n"
    )
    loader = (
        "import importlib.util,pathlib,signal,sys\n"
        f"spec=importlib.util.spec_from_file_location('owner',{str(SCRIPT)!r})\n"
        "m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)\n"
    )
    # Non-Darwin cleanup intentionally spends its full grace. Keep nested
    # fixture budgets below the assertion deadline, with time for inner cleanup.
    wrapper = tmp_path / "wrapper.py"
    wrapper.write_text(
        loader
        + "with m.TerminationGuard() as guard, m.ExitStack() as cleanup:\n"
        + " with guard.registration():\n"
        + f"  child=m.spawn_owned([sys.executable,{str(native)!r}]);cleanup.callback(m.stop_owned,child,grace=.3)\n"
        + " try: m.wait_owned(child,8)\n"
        + " finally: guard.cleaning=True\n"
    )
    outer = tmp_path / "outer.py"
    outer.write_text(
        loader
        + "before=signal.getsignal(signal.SIGTERM)\n"
        + "try:\n"
        + f" m.run_owned_command([sys.executable,{str(wrapper)!r}],cwd=pathlib.Path({str(tmp_path)!r}),timeout=8,cleanup_grace=2)\n"
        + "except ValueError:\n"
        + " assert signal.getsignal(signal.SIGTERM)==before\n"
        + f" pathlib.Path({str(restored)!r}).touch();sys.exit(2)\n"
    )
    process = subprocess.Popen([sys.executable, str(outer)])
    try:
        deadline = time.monotonic() + 5
        while not ready.exists() and time.monotonic() < deadline:
            assert process.poll() is None
            time.sleep(0.01)
        assert ready.exists()
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=6) == 2
        assert restored.exists()
        assert stopped.read_text() == str(signal.SIGTERM)
    finally:
        release.touch()
        process.wait(timeout=10)


def test_outer_owner_rejects_fast_oversized_output(tmp_path, monkeypatch):
    import sys

    module = subject()
    spawn = module.spawn_owned

    def already_completed(*args, **kwargs):
        process = spawn(*args, **kwargs)
        module.wait_owned(process, 5)
        return process

    monkeypatch.setattr(module, "spawn_owned", already_completed)
    with pytest.raises(ValueError, match="output exceeds budget"):
        module.run_owned_command(
            [sys.executable, "-c", "import sys;sys.stdout.write('x'*(9*1024*1024))"],
            cwd=tmp_path,
            timeout=5,
        )


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


def synthetic_editor_observations():
    original = {
        "name": "Existing rendered view",
        "kind": "web",
        "runner": "/unit/renderer",
        "subject": "workbench-connected-workflow",
    }
    renamed = {**original, "name": "Saved rendered view"}
    return {
        "renderer_original": original,
        "renderer_renamed": renamed,
        "url_mode": {
            "name": renamed["name"],
            "kind": "web",
            "url": "http://127.0.0.1:1234/unit",
            "expectText": "Controlled navigation",
        },
        "renderer_restored": dict(renamed),
    }


def synthetic_receipt(root) -> dict[str, Any]:
    """Synthetic validator unit data, never native/UI acceptance evidence."""
    module = subject()

    def descriptor(name, value):
        path = root / name
        path.write_text(json.dumps(value))
        result = {"path": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        if name.endswith("_verdict.json"):
            result["exit_code"] = 1 if value["status"] == "FAIL" else 0
        return result

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
        "loaded_page": (root / "Packaged 雪 Resources/index.html").as_uri(),
        "required_phase_ids": list(module.REQUIRED_PHASES),
        "phases": [
            {
                "id": name,
                "status": "pass",
                "observations": {"web_editor": synthetic_editor_observations()}
                if name == "edit-save"
                else {
                    "reduced_motion": True,
                    "normal_motion_verified": False,
                    "os_reduced_motion": False,
                    "before": "[]",
                    "after": "[]",
                }
                if name == "running-motion"
                else {},
            }
            for name in module.REQUIRED_PHASES
        ],
        "assertions": 20,
        "cleanup": {"bridge_shutdown_awaited": True, "visible_windows": 0},
        "snapshots": images,
        "history": descriptor("state.json", history),
        "final_tree": descriptor("final-tree.json", tree),
        "negative_tree": descriptor("negative-tree.json", {"unit_fixture": True}),
    }
    native = descriptor("native-report.json", receipt)
    return dict(
        receipt,
        native_report=native,
        driver_sha256=module.digest(SCRIPT),
        layout_verdict=descriptor(
            "layout_verdict.json",
            {"status": "PASS", "scenario": "workbench-connected-workflow", "findings": []},
        ),
        negative_verdict=descriptor(
            "negative_verdict.json",
            {
                "status": "FAIL",
                "scenario": "workbench-negative-control",
                "findings": [
                    {
                        "severity": "error",
                        "rule": "sibling-overlap",
                        "nodeID": "acceptance-negative-b",
                    }
                ],
            },
        ),
        identities={
            "app": {"resource_root": str(root / "Packaged 雪 Resources")},
            "consumer": {"test": True},
        },
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


def synthetic_motion_receipt(root, *, reduced=False, mode="detached"):
    """Typed validator fixtures only; not native motion measurements."""
    position = {"x": 10, "y": 20}

    def native(at):
        return {
            "uptime_seconds": at,
            "os_reduced_motion": False,
            "frontmost_pid": 123,
            "cursor": dict(position),
            "visible_windows": 0,
            "key_windows": 0,
            "view_has_window": mode == "invisible-window",
            "view_window_visible": False,
            "view_window_key": False,
        }

    samples = []
    for index, checkpoint in enumerate(
        ("page-ready", "running-before", "running-after", "recreated-page-ready")
    ):
        web = {
            "at": index * 10 if index < 3 else 0,
            "document_id": "original-document" if index < 3 else "recreated-document",
            "reduced": reduced,
            "no_preference": not reduced,
            "hidden": True,
            "visibility": "hidden",
            "stage": "running",
            "changes": [],
            "changes_dropped": 0,
            "animations": []
            if reduced
            else [
                {"id": animation_id, "name": name, "time": index * 10, "state": "running"}
                for animation_id, name in enumerate(
                    ("orbit", "breathe", "scan-light", "inspection-tilt"), start=1
                )
            ],
        }
        samples.append(
            {
                "checkpoint": checkpoint,
                "native_before": native(index * 2),
                "native_after": native(index * 2 + 1),
                "web": web,
            }
        )
    receipt = {
        "phases": [{} for _ in range(5)]
        + [{"observations": {"reduced_motion": reduced, "normal_motion_verified": not reduced}}],
        "motion_diagnostics": {
            "schema": 1,
            "host_mode": mode,
            "samples": samples,
            "initial_cursor": position,
            "initial_frontmost_pid": 123,
            "final_native": native(10),
            "accessibility_changes": [],
            "accessibility_changes_dropped": 0,
            "environment_variable_names": ["HOME", "PATH", "TMPDIR"],
        },
    }
    retain_motion_raw(root, receipt)
    return receipt


def retain_motion_raw(root, receipt):
    for index, sample in enumerate(receipt["motion_diagnostics"]["samples"]):
        path = root / f"motion-sample-{index}.json"
        raw = {key: sample[key] for key in ("checkpoint", "native_before", "native_after")}
        raw["web_json"] = json.dumps(sample["web"])
        path.write_text(json.dumps(raw))
        sample["raw_artifact"] = {"path": path.name, "sha256": subject().digest(path)}


@pytest.mark.parametrize("mode", ["detached", "invisible-window"])
@pytest.mark.parametrize("reduced", [False, True])
def test_motion_assessment_preserves_actual_mode_and_disagreement(tmp_path, mode, reduced):
    receipt = synthetic_motion_receipt(tmp_path, mode=mode, reduced=reduced)
    result = subject().assess_motion(receipt, tmp_path)
    assert result["normal_css_timeline"] == ("unavailable" if reduced else "verified")
    assert result["media_os_agreement"] is (not reduced)
    assert result["host_mode"] == mode and result["sampled_noninterference"]
    assert receipt["motion_diagnostics"]["samples"][1]["web"]["reduced"] is reduced


@pytest.mark.parametrize(
    "mutation",
    [
        "paused",
        "stationary",
        "wrong-name",
        "cursor",
        "foreground",
        "visible",
        "association",
        "dropped",
        "phase",
        "media-changed",
    ],
)
def test_motion_cannot_claim_normal_without_advance_and_sampled_noninterference(tmp_path, mutation):
    receipt = synthetic_motion_receipt(tmp_path)
    data = receipt["motion_diagnostics"]
    sample = data["samples"][2]
    if mutation == "paused":
        sample["web"]["animations"][0]["state"] = "paused"
    elif mutation == "stationary":
        sample["web"]["animations"] = copy.deepcopy(data["samples"][1]["web"]["animations"])
    elif mutation == "wrong-name":
        sample["web"]["animations"][0]["name"] = "unrelated"
    elif mutation == "cursor":
        sample["native_after"]["cursor"]["x"] += 1
    elif mutation == "foreground":
        sample["native_after"]["frontmost_pid"] += 1
    elif mutation == "visible":
        sample["native_after"]["visible_windows"] = 1
    elif mutation == "association":
        sample["native_after"]["view_has_window"] = True
    elif mutation == "dropped":
        sample["web"]["changes_dropped"] = 1
    elif mutation == "phase":
        receipt["phases"][5]["observations"] = {}
    else:
        sample["web"].update(reduced=True, no_preference=False)
    retain_motion_raw(tmp_path, receipt)
    assert subject().assess_motion(receipt, tmp_path)["normal_css_timeline"] == "unavailable"


@pytest.mark.parametrize(
    "mutation",
    ["boolean", "nan", "missing", "raw", "mode", "timing", "history", "environment-values"],
)
def test_motion_malformed_or_unbound_observations_refuse(tmp_path, mutation):
    receipt = synthetic_motion_receipt(tmp_path)
    data = receipt["motion_diagnostics"]
    if mutation == "boolean":
        data["samples"][1]["web"]["reduced"] = 0
    elif mutation == "nan":
        data["samples"][1]["web"]["animations"][0]["time"] = float("nan")
    elif mutation == "missing":
        data["samples"].pop()
    elif mutation == "raw":
        path = tmp_path / data["samples"][0]["raw_artifact"]["path"]
        path.write_text("{}")
    elif mutation == "mode":
        data["host_mode"] = "visible"
    elif mutation == "timing":
        data["samples"][1]["native_after"]["uptime_seconds"] = -1
    elif mutation == "history":
        data["samples"][1]["web"]["changes"] = [{"at": 1, "matches": "true", "media": "reduce"}]
    else:
        data["environment_variable_names"] = {"HOME": "do-not-record-values"}
    with pytest.raises(ValueError):
        subject().assess_motion(receipt, tmp_path)


def test_motion_unknown_foreground_is_not_sampled_noninterference(tmp_path):
    receipt = synthetic_motion_receipt(tmp_path)
    data = receipt["motion_diagnostics"]
    data["initial_frontmost_pid"] = -1
    data["final_native"]["frontmost_pid"] = -1
    for sample in data["samples"]:
        for side in ("native_before", "native_after"):
            sample[side]["frontmost_pid"] = -1
    retain_motion_raw(tmp_path, receipt)
    result = subject().assess_motion(receipt, tmp_path)
    assert not result["sampled_noninterference"]
    assert result["normal_css_timeline"] == "unavailable"


def test_explicit_motion_mode_rejects_invalid_choice_before_any_identity_or_launch(
    tmp_path, monkeypatch
):
    import argparse

    module = subject()
    monkeypatch.setattr(module, "load_identity", lambda *_: pytest.fail("invalid mode reached IO"))
    with pytest.raises(ValueError, match="motion host"):
        module._run(argparse.Namespace(motion_host="visible"), tmp_path, tmp_path, None, None)


def test_retained_report_cannot_promote_reduced_native_motion(tmp_path):
    module = subject()
    receipt = synthetic_receipt(tmp_path)
    motion = synthetic_motion_receipt(tmp_path, reduced=True)
    path = tmp_path / receipt["native_report"]["path"]
    native = json.loads(path.read_text())
    native["phases"][5]["observations"].update(motion["phases"][5]["observations"])
    native["motion_diagnostics"] = motion["motion_diagnostics"]
    path.write_text(json.dumps(native))
    receipt.update(native)
    receipt["native_report"]["sha256"] = module.digest(path)
    receipt["motion_assessment"] = module.assess_motion(native, tmp_path)
    assert module.validate_report(receipt, tmp_path) is receipt
    receipt["motion_assessment"]["normal_css_timeline"] = "verified"
    with pytest.raises(ValueError, match="motion assessment"):
        module.validate_report(receipt, tmp_path)


@pytest.mark.parametrize(
    "mutation",
    ["missing", "boolean", "claim", "reduced-animation", "empty-normal", "paused", "nan"],
)
def test_original_motion_payload_cannot_be_missing_or_forge_advance(tmp_path, mutation):
    receipt = synthetic_receipt(tmp_path)
    observed = receipt["phases"][5]["observations"]
    if mutation == "missing":
        observed.clear()
    elif mutation == "boolean":
        observed["reduced_motion"] = 1
    elif mutation == "claim":
        observed["normal_motion_verified"] = True
    elif mutation == "reduced-animation":
        observed["before"] = '[{"time":0,"state":"running"}]'
    else:
        observed.update(reduced_motion=False, normal_motion_verified=True)
        if mutation == "paused":
            observed.update(
                before='[{"time":0,"state":"paused"}]', after='[{"time":1,"state":"paused"}]'
            )
        elif mutation == "nan":
            observed.update(
                before='[{"time":NaN,"state":"running"}]', after='[{"time":1,"state":"running"}]'
            )
    with pytest.raises(ValueError, match="motion"):
        subject().validate_native_receipt(receipt, tmp_path)


def test_original_normal_motion_payload_requires_actual_running_time_advance():
    subject().validate_motion_phase(
        {
            "reduced_motion": False,
            "normal_motion_verified": True,
            "os_reduced_motion": False,
            "before": '[{"time":1,"state":"running"}]',
            "after": '[{"time":181,"state":"running"}]',
        }
    )


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


@pytest.mark.parametrize("interruption", ["SIGTERM", "SIGINT"])
def test_run_interruption_closes_owned_native_process(tmp_path, interruption):
    """Real process-control fixture; neither child nor identity stub is UI evidence."""
    import os
    import signal
    import subprocess
    import sys
    import time

    app = tmp_path / "fixture.app"
    executable = app / "Contents/MacOS/VerdictUIWorkbench"
    executable.parent.mkdir(parents=True)
    executable.write_text(
        f"#!{sys.executable}\n"
        "import json,os,pathlib,signal,sys,time\n"
        "root=pathlib.Path(json.loads(pathlib.Path(sys.argv[2]).read_text())['output_root'])\n"
        "def stop(sig,frame):\n"
        " (root/'native-stopped').write_text(str(sig))\n"
        " sys.exit(2)\n"
        "signal.signal(signal.SIGTERM,stop)\n"
        "(root/'native-ready').write_text(str(os.getpid()))\n"
        "while True: time.sleep(.02)\n"
    )
    executable.chmod(0o700)
    output = tmp_path / "run"
    output.mkdir(mode=0o700)
    worker = tmp_path / "worker.py"
    worker.write_text(
        "import argparse,importlib.util,pathlib,signal,sys,types\n"
        f"spec=importlib.util.spec_from_file_location('acceptance',{str(SCRIPT)!r})\n"
        "module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)\n"
        "module.load_identity=lambda root: types.SimpleNamespace(validate_app=lambda *a:{'fixture':True},validate_consumer=lambda *a:{'fixture':True})\n"
        f"root=pathlib.Path({str(tmp_path)!r});output=root/'run'\n"
        "old=signal.getsignal(signal.SIGTERM)\n"
        "try:\n"
        " module.run(argparse.Namespace(app=root/'fixture.app',consumer_runner=root/'unused',consumer_build_receipt=root/'unused.json',timeout_seconds=20),root,output)\n"
        "except ValueError as error:\n"
        " (output/'interrupted').write_text(str(error))\n"
        " assert signal.getsignal(signal.SIGTERM)==old\n"
        " sys.exit(2)\n"
    )
    process = subprocess.Popen([sys.executable, str(worker)])
    native_pid = None
    try:
        deadline = time.monotonic() + 8
        while not (output / "native-ready").exists() and time.monotonic() < deadline:
            assert process.poll() is None
            time.sleep(0.02)
        native_pid = int((output / "native-ready").read_text())
        process.send_signal(getattr(signal, interruption))
        assert process.wait(timeout=8) == 2
        assert (output / "native-stopped").read_text() == str(signal.SIGTERM)
        assert "interrupted" in (output / "interrupted").read_text()
        with pytest.raises(ProcessLookupError):
            os.kill(native_pid, 0)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=3)
        if native_pid:
            try:
                os.killpg(native_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def test_stale_wrapper_cannot_admit_old_report(tmp_path):
    receipt = synthetic_receipt(tmp_path)
    receipt["driver_sha256"] = "0" * 64
    with pytest.raises(ValueError, match="wrapper identity"):
        subject().validate_report(receipt, tmp_path)


def test_negative_control_requires_actual_named_overlap(tmp_path):
    receipt = synthetic_receipt(tmp_path)
    path = tmp_path / "negative_verdict.json"
    data = json.loads(path.read_text())
    data["findings"] = []
    path.write_text(json.dumps(data))
    receipt["negative_verdict"]["sha256"] = subject().digest(path)
    with pytest.raises(ValueError, match="negative control"):
        subject().validate_report(receipt, tmp_path)


@pytest.mark.parametrize("status", ["PASS", "FAIL"])
@pytest.mark.parametrize("entry", ["imported", "cli"])
def test_real_wrapper_preserves_measured_layout_outcome(
    tmp_path, monkeypatch, capsys, status, entry
):
    """Real wrapper/process contract with labelled executable fixtures, not UI evidence."""
    import argparse
    import sys
    import types

    module = subject()
    template = tmp_path / "synthetic-native"
    template.mkdir()
    synthetic_receipt(template)
    native_path = template / "native-report.json"
    data = json.loads(native_path.read_text())
    data["motion_diagnostics"] = synthetic_motion_receipt(template, reduced=True)[
        "motion_diagnostics"
    ]
    native_path.write_text(json.dumps(data))
    for name in ("layout_verdict.json", "negative_verdict.json"):
        (template / name).unlink()
    app = tmp_path / "fixture.app"
    native = app / "Contents/MacOS/VerdictUIWorkbench"
    native.parent.mkdir(parents=True)
    native.write_text(
        f"#!{sys.executable}\n"
        "import json,pathlib,shutil,sys\n"
        "config=json.loads(pathlib.Path(sys.argv[2]).read_text())\n"
        "output=pathlib.Path(config['output_root'])\n"
        f"template=pathlib.Path({str(template)!r})\n"
        "for path in template.iterdir(): shutil.copyfile(path,output/path.name)\n"
        "path=output/'native-report.json';data=json.loads(path.read_text())\n"
        "data['run_id']=config['run_id'];path.write_text(json.dumps(data))\n"
    )
    native.chmod(0o700)
    helper = app / "Contents/Helpers/verdictui"
    helper.parent.mkdir()
    helper.write_text(
        f"#!{sys.executable}\n"
        "import json,sys\n"
        "negative='negative-tree.json' in sys.argv[2]\n"
        f"status='FAIL' if negative else {status!r}\n"
        "print(json.dumps({'status':status,'scenario':sys.argv[-1],"
        "'findings':[{'severity':'error','rule':'sibling-overlap','nodeID':'acceptance-negative-b' if negative else 'observed-b'}] if status=='FAIL' else []}))\n"
        "sys.exit(1 if status=='FAIL' else 0)\n"
    )
    helper.chmod(0o700)
    monkeypatch.setattr(
        module,
        "load_identity",
        lambda _root: types.SimpleNamespace(
            validate_app=lambda *_args: {"resource_root": str(template / "Packaged 雪 Resources")},
            validate_consumer=lambda *_args: {"unit_fixture": True},
        ),
    )
    runner = tmp_path / "consumer-fixture"
    runner.touch()
    build = tmp_path / "consumer-fixture.json"
    build.write_text("{}")
    output = tmp_path / "run"
    args = argparse.Namespace(
        app=app,
        consumer_runner=runner,
        consumer_build_receipt=build,
        output=output,
        timeout_seconds=10,
    )
    if entry == "imported":
        output.mkdir(mode=0o700)
        report = module.run(args, tmp_path, output)
        assert module.validate_report(report, output) is report
    else:
        monkeypatch.setattr(
            sys,
            "argv",
            [
                str(SCRIPT),
                "--app",
                str(app),
                "--consumer-runner",
                str(runner),
                "--consumer-build-receipt",
                str(build),
                "--output",
                str(output),
            ],
        )
        assert module.main() == (0 if status == "PASS" else 1)
        assert f"WORKBENCH ACCEPTANCE {status}:" in capsys.readouterr().out
        report = json.loads((output / "report.json").read_text())
    assert report["status"] == "pass"  # The native workflow completed; layout is separate.
    assert json.loads(module.artifact_bytes(output, report["layout_verdict"]))["status"] == status


def test_measured_layout_verdict_must_match_recorded_exit_code(tmp_path):
    module = subject()
    receipt = synthetic_receipt(tmp_path)
    receipt["layout_verdict"]["exit_code"] = 1
    with pytest.raises(ValueError, match="exit code disagree"):
        module.validate_report(receipt, tmp_path)


@pytest.mark.parametrize(
    "mutation", ["missing", "malformed", "lost-subject", "mixed-url", "changed-runner"]
)
def test_web_editor_roundtrip_observations_are_required(tmp_path, mutation):
    receipt = synthetic_receipt(tmp_path)
    observed = receipt["phases"][2]["observations"]["web_editor"]
    if mutation == "missing":
        receipt["phases"][2]["observations"].clear()
    elif mutation == "malformed":
        receipt["phases"][2]["observations"] = None
    elif mutation == "lost-subject":
        observed["renderer_renamed"].pop("subject")
    elif mutation == "mixed-url":
        observed["url_mode"]["runner"] = observed["renderer_original"]["runner"]
    else:
        observed["renderer_restored"]["runner"] = "/changed/renderer"
    with pytest.raises(ValueError, match="web editor roundtrip"):
        subject().validate_native_receipt(receipt, tmp_path)


def test_web_renderer_editor_browser_contract(tmp_path):
    """Actual Chromium form behavior; native persistence is separately exercised."""
    import sys

    from playwright.sync_api import sync_playwright

    path = SCRIPT.parent / "workbench-smoke.py"
    spec = importlib.util.spec_from_file_location("editor_smoke", path)
    assert spec and spec.loader
    smoke = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = smoke
    spec.loader.exec_module(smoke)
    with sync_playwright() as engine:
        browser = engine.chromium.launch()
        try:
            page = browser.new_page(viewport={"width": 1000, "height": 700})
            page.add_init_script(smoke.MOCK_BRIDGE)
            page.goto(
                (SCRIPT.parents[1] / "Sources/VerdictUIWorkbench/Resources/index.html").as_uri()
            )
            smoke.receive(page, smoke.FIXTURE_STATE)
            run = smoke.SmokeRun()
            smoke.web_source_editing(page, "chromium", tmp_path, run)
            assert len(run.passed) >= 12 and not run.failures
        finally:
            browser.close()


def test_renderer_editor_png_is_required(tmp_path):
    receipt = synthetic_receipt(tmp_path)
    receipt["snapshots"] = [row for row in receipt["snapshots"] if row["phase"] != "web-renderer"]
    with pytest.raises(ValueError, match="PNG phases"):
        subject().validate_native_receipt(receipt, tmp_path)


@pytest.mark.parametrize(
    "mutation",
    ["missing", "build-tree", "remote", "query", "fragment", "root-missing", "root-relative"],
)
def test_loaded_page_must_match_packaged_resource_identity(tmp_path, mutation):
    module = subject()
    receipt = synthetic_receipt(tmp_path)
    if mutation == "missing":
        receipt.pop("loaded_page")
    elif mutation == "build-tree":
        receipt["loaded_page"] = (tmp_path / ".build/Resources/index.html").as_uri()
    elif mutation == "remote":
        receipt["loaded_page"] = "https://example.invalid/index.html"
    elif mutation == "query":
        receipt["loaded_page"] += "?replacement=true"
    elif mutation == "fragment":
        receipt["loaded_page"] += "#replacement"
    elif mutation == "root-missing":
        receipt["identities"]["app"].clear()
        receipt["identities"]["app"]["unit_fixture"] = True
    else:
        receipt["identities"]["app"]["resource_root"] = "relative/Resources"
    native_path = tmp_path / "native-report.json"
    native = json.loads(native_path.read_text())
    native.pop("loaded_page", None)
    if "loaded_page" in receipt:
        native["loaded_page"] = receipt["loaded_page"]
    native_path.write_text(json.dumps(native))
    receipt["native_report"]["sha256"] = module.digest(native_path)
    with pytest.raises(ValueError, match="loaded page"):
        module.validate_report(receipt, tmp_path)


@pytest.mark.skipif(sys.platform != "darwin", reason="Darwin system path alias")
def test_loaded_page_accepts_verified_darwin_var_alias(tmp_path):
    module = subject()
    assert Path("/var").resolve() == Path("/private/var")
    receipt = synthetic_receipt(tmp_path)
    receipt["identities"]["app"]["resource_root"] = "/private/var/folders/workbench/Resources"
    receipt["loaded_page"] = "file:///var/folders/workbench/Resources/index.html"
    native_path = tmp_path / "native-report.json"
    native = json.loads(native_path.read_text())
    native["loaded_page"] = receipt["loaded_page"]
    native_path.write_text(json.dumps(native))
    receipt["native_report"]["sha256"] = module.digest(native_path)
    assert module.validate_report(receipt, tmp_path)["status"] == "pass"


def test_loaded_page_rejects_arbitrary_alias_even_to_packaged_assets(tmp_path):
    module = subject()
    receipt = synthetic_receipt(tmp_path)
    resources = Path(receipt["identities"]["app"]["resource_root"])
    resources.mkdir()
    (resources / "index.html").write_text("<title>packaged</title>")
    alias = tmp_path / "build-tree"
    alias.symlink_to(resources, target_is_directory=True)
    receipt["loaded_page"] = (alias / "index.html").as_uri()
    native_path = tmp_path / "native-report.json"
    native = json.loads(native_path.read_text())
    native["loaded_page"] = receipt["loaded_page"]
    native_path.write_text(json.dumps(native))
    receipt["native_report"]["sha256"] = module.digest(native_path)
    with pytest.raises(ValueError, match="loaded page"):
        module.validate_report(receipt, tmp_path)


def complete_motion_report(root):
    module = subject()
    receipt = synthetic_receipt(root)
    receipt["motion_diagnostics"] = synthetic_motion_receipt(root)["motion_diagnostics"]
    receipt["phases"][5]["observations"].update(
        reduced_motion=False,
        normal_motion_verified=True,
        before=json.dumps([{"time": 10, "state": "running"}]),
        after=json.dumps([{"time": 20, "state": "running"}]),
    )
    receipt["motion_assessment"] = module.assess_motion(receipt, root)
    sync_motion_native(root, receipt)
    assert module.validate_report(receipt, root) is receipt
    return receipt


def sync_motion_native(root, receipt):
    path = root / receipt["native_report"]["path"]
    native = json.loads(path.read_text())
    native["phases"] = receipt["phases"]
    if "motion_diagnostics" in receipt:
        native["motion_diagnostics"] = receipt["motion_diagnostics"]
    else:
        native.pop("motion_diagnostics", None)
    path.write_text(json.dumps(native))
    receipt["native_report"]["sha256"] = subject().digest(path)


@pytest.mark.parametrize("mutation", ["media", "native", "cursor", "timestamp"])
def test_motion_raw_boolean_number_alias_is_rejected(tmp_path, mutation):
    receipt = complete_motion_report(tmp_path)
    sample = receipt["motion_diagnostics"]["samples"][0]
    if mutation == "cursor":
        data = receipt["motion_diagnostics"]
        data["initial_cursor"]["x"] = 0
        data["final_native"]["cursor"]["x"] = 0
        for reading in data["samples"]:
            for side in ("native_before", "native_after"):
                reading[side]["cursor"]["x"] = 0
        retain_motion_raw(tmp_path, receipt)
    path = tmp_path / sample["raw_artifact"]["path"]
    raw = json.loads(path.read_text())
    if mutation == "native":
        raw["native_before"]["os_reduced_motion"] = 0
    elif mutation == "cursor":
        raw["native_before"]["cursor"]["x"] = False
    else:
        web = json.loads(raw["web_json"])
        web["reduced" if mutation == "media" else "at"] = 0 if mutation == "media" else False
        raw["web_json"] = json.dumps(web)
    path.write_text(json.dumps(raw))
    sample["raw_artifact"]["sha256"] = subject().digest(path)
    sync_motion_native(tmp_path, receipt)
    with pytest.raises(ValueError, match="raw observation differs"):
        subject().validate_report(receipt, tmp_path)


def test_motion_json_numbers_allow_roundtrip_representation_without_boolean_alias():
    module = subject()
    assert module.same_json({"at": [10.0]}, {"at": [10]})
    assert not module.same_json({"at": [False]}, {"at": [0]})


@pytest.mark.parametrize("where", ["native-and-report", "native-only", "outer-type-alias"])
def test_motion_assessment_requires_exact_native_diagnostics(tmp_path, where):
    receipt = complete_motion_report(tmp_path)
    if where == "native-and-report":
        del receipt["motion_diagnostics"]
        sync_motion_native(tmp_path, receipt)
    elif where == "native-only":
        path = tmp_path / receipt["native_report"]["path"]
        native = json.loads(path.read_text())
        del native["motion_diagnostics"]
        path.write_text(json.dumps(native))
        receipt["native_report"]["sha256"] = subject().digest(path)
    else:
        receipt["motion_assessment"]["sampled_noninterference"] = 1
    with pytest.raises(ValueError, match="motion assessment"):
        subject().validate_report(receipt, tmp_path)


@pytest.mark.parametrize(
    "mutation", ["reversed", "same-time", "new-document", "wrong-page", "reused-recreated"]
)
def test_motion_requires_same_document_forward_clock(tmp_path, mutation):
    receipt = synthetic_motion_receipt(tmp_path)
    samples = receipt["motion_diagnostics"]["samples"]
    if mutation == "reversed":
        samples[2]["web"]["at"] = 1
    elif mutation == "same-time":
        samples[2]["web"]["at"] = samples[1]["web"]["at"]
    elif mutation == "new-document":
        samples[2]["web"]["document_id"] = "unexpected-navigation"
    elif mutation == "wrong-page":
        samples[0]["web"]["document_id"] = "unrelated-page"
    else:
        samples[3]["web"]["document_id"] = samples[2]["web"]["document_id"]
    retain_motion_raw(tmp_path, receipt)
    result = subject().assess_motion(receipt, tmp_path)
    assert result["normal_css_timeline"] == "unavailable"
    assert not result["same_document_clock_ordered"]


@pytest.mark.parametrize("advances", [False, True])
def test_motion_duplicate_names_track_animation_identity_across_reordering(tmp_path, advances):
    receipt = synthetic_motion_receipt(tmp_path)
    before = []
    after = []
    for index, name in enumerate(("orbit", "breathe", "scan-light", "inspection-tilt")):
        pair = [
            {"id": index * 2 + offset, "name": name, "time": offset * 10, "state": "running"}
            for offset in (1, 2)
        ]
        before.extend(copy.deepcopy(pair))
        for item in reversed(pair):
            item["time"] += 5 if advances else 0
            after.append(item)
    samples = receipt["motion_diagnostics"]["samples"]
    samples[1]["web"]["animations"] = before
    samples[2]["web"]["animations"] = after
    retain_motion_raw(tmp_path, receipt)
    result = subject().assess_motion(receipt, tmp_path)
    assert result["normal_css_timeline"] == ("verified" if advances else "unavailable")


@pytest.mark.parametrize("mutation", ["missing", "bool", "duplicate", "replaced"])
def test_motion_animation_identity_cannot_be_missing_aliased_or_replaced(tmp_path, mutation):
    receipt = synthetic_motion_receipt(tmp_path)
    rows = receipt["motion_diagnostics"]["samples"][2]["web"]["animations"]
    if mutation == "missing":
        del rows[0]["id"]
    elif mutation == "bool":
        rows[0]["id"] = True
    elif mutation == "duplicate":
        rows[1]["id"] = rows[0]["id"]
    else:
        rows[0]["id"] = 999
    retain_motion_raw(tmp_path, receipt)
    if mutation == "replaced":
        assert subject().assess_motion(receipt, tmp_path)["normal_css_timeline"] == "unavailable"
    else:
        with pytest.raises(ValueError, match="animation"):
            subject().assess_motion(receipt, tmp_path)


def test_default_producer_refuses_legacy_native_without_diagnostics(tmp_path, monkeypatch, capsys):
    module = subject()
    validate = module.validate_native_receipt

    def legacy_native(receipt, root):
        value = validate(receipt, root)
        value.pop("motion_diagnostics", None)
        return value

    monkeypatch.setattr(module, "validate_native_receipt", legacy_native)
    monkeypatch.setattr(sys.modules[__name__], "subject", lambda: module)
    with pytest.raises(ValueError, match="requested motion host was not observed"):
        test_real_wrapper_preserves_measured_layout_outcome(
            tmp_path, monkeypatch, capsys, "PASS", "imported"
        )
    assert json.loads((tmp_path / "run/config.json").read_text())["motion_host"] == "detached"
