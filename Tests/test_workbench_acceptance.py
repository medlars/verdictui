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
    wrapper = tmp_path / "wrapper.py"
    wrapper.write_text(
        loader
        + "with m.TerminationGuard() as guard, m.ExitStack() as cleanup:\n"
        + " with guard.registration():\n"
        + f"  child=m.spawn_owned([sys.executable,{str(native)!r}]);cleanup.callback(m.stop_owned,child)\n"
        + " try: m.wait_owned(child,8)\n"
        + " finally: guard.cleaning=True\n"
    )
    outer = tmp_path / "outer.py"
    outer.write_text(
        loader
        + "before=signal.getsignal(signal.SIGTERM)\n"
        + "try:\n"
        + f" m.run_owned_command([sys.executable,{str(wrapper)!r}],cwd=pathlib.Path({str(tmp_path)!r}),timeout=8)\n"
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
