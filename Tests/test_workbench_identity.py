"""Stale source, replaced binaries and missing builds cannot certify current UI."""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import workbench_identity as identity


@pytest.fixture
def project(tmp_path):
    root = tmp_path / "project"
    for name, body in {
        "Package.swift": "package",
        "Package.resolved": "lock",
        "Sources/VerdictUIWorkbench/Resources/index.html": "<button id='run'>Run</button>",
        "Sources/VerdictUIWorkbench/main.swift": "actual source",
        "assets/icon.icns": "icon",
        "scripts/build-workbench.sh": "recipe",
        "scripts/workbench_identity.py": "identity recipe",
    }.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
    return root


@pytest.fixture
def packaged(project, tmp_path, monkeypatch):
    app = tmp_path / "VerdictUI.app"
    resources = app / identity.RESOURCE_ROOT
    resources.mkdir(parents=True)
    (resources / "index.html").write_bytes(
        (project / "Sources/VerdictUIWorkbench/Resources/index.html").read_bytes()
    )
    for relative in ("Contents/MacOS/VerdictUIWorkbench", "Contents/Helpers/verdictui"):
        binary = app / relative
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_bytes(b"unit fixture executable")
        binary.chmod(0o700)
    identity.stamp_app(project, app, identity.source_fingerprint(project), "debug", "unit fixture")
    # Signing is an injected boundary here; packaged acceptance uses the real tool.
    monkeypatch.setattr(identity.subprocess, "run", lambda *a, **kw: None)
    return app


@pytest.mark.parametrize(
    "changed",
    [
        "Sources/VerdictUIWorkbench/main.swift",
        "Sources/ignored-but-compiled.swift",
        "Package.resolved",
    ],
)
def test_current_source_changes_refuse_stale_packaged_app(project, packaged, changed):
    assert identity.validate_app(project, packaged)["kind"] == "workbench"
    (project / changed).write_text("different real build input")
    with pytest.raises(ValueError, match="current source"):
        identity.validate_app(project, packaged)


def test_changed_source_during_build_cannot_receive_stamp(project, packaged):
    before = identity.source_fingerprint(project)
    stamp_before = (packaged / identity.STAMP).read_bytes()
    (project / "Sources/new.swift").write_text("changed during compiler execution")
    with pytest.raises(ValueError, match="while building"):
        identity.stamp_app(project, packaged, before, "debug", "unit fixture")
    assert (packaged / identity.STAMP).read_bytes() == stamp_before


def test_packaged_assets_cannot_be_substituted_despite_matching_source_stamp(project, packaged):
    (packaged / identity.RESOURCE_ROOT / "index.html").write_text("stale rendered content")
    with pytest.raises(ValueError, match="resources"):
        identity.validate_app(project, packaged)


def test_failed_signature_cannot_be_admitted(project, packaged, monkeypatch):
    def fail(*args, **kwargs):
        if kwargs.get("check"):
            raise subprocess.CalledProcessError(1, ["codesign"])
        return subprocess.CompletedProcess(["codesign"], 1)

    monkeypatch.setattr(identity.subprocess, "run", fail)
    with pytest.raises(subprocess.CalledProcessError):
        identity.validate_app(project, packaged)


def test_nonexecutable_or_missing_helper_is_unavailable(project, packaged):
    (packaged / "Contents/Helpers/verdictui").chmod(0o600)
    with pytest.raises(ValueError, match="executable"):
        identity.validate_app(project, packaged)


@pytest.mark.parametrize("fault", ["missing", "symlink", "oversized", "nonobject", "schema"])
def test_invalid_build_stamp_is_unavailable(project, packaged, fault):
    path = packaged / identity.STAMP
    if fault == "missing":
        path.unlink()
    elif fault == "symlink":
        target = path.with_suffix(".real")
        path.rename(target)
        path.symlink_to(target)
    elif fault == "oversized":
        path.write_text(" " * (64 * 1024 + 1))
    elif fault == "nonobject":
        path.write_text("[]")
    else:
        value = json.loads(path.read_text())
        value["schema"] = True
        path.write_text(json.dumps(value))
    with pytest.raises(ValueError):
        identity.validate_app(project, packaged)


def test_symlinked_source_never_reads_its_target(project, tmp_path):
    target = tmp_path / "private.swift"
    target.write_text("private content must not be read")
    (project / "Sources/link.swift").symlink_to(target)
    with pytest.raises(ValueError, match="symlink"):
        identity.source_fingerprint(project)


@pytest.mark.parametrize("budget", ["MAX_BYTES", "MAX_FILES", "DEADLINE_SECONDS"])
def test_scan_limits_are_unavailable_not_partial_fingerprints(project, monkeypatch, budget):
    monkeypatch.setattr(identity, budget, 0)
    with pytest.raises(ValueError, match="budget|deadline|expired"):
        identity.source_fingerprint(project)


def test_build_outputs_do_not_invalidate_source_identity(project):
    before = identity.source_fingerprint(project)
    scratch = project / ".build/generated.swift"
    scratch.parent.mkdir()
    scratch.write_text("generated output outside source input roots")
    assert identity.source_fingerprint(project) == before


@pytest.fixture
def consumer(project, tmp_path):
    fixture = tmp_path / "fixture"
    (fixture / "Sources").mkdir(parents=True)
    (fixture / "Package.swift").write_text("unit package")
    (fixture / "Sources/main.swift").write_text("unit consumer")
    runner = fixture / "runner"
    runner.write_text("unit executable")
    runner.chmod(0o700)
    value = {
        "schema": 1,
        "kind": "consumer",
        "framework_source_sha256": identity.source_fingerprint(project),
        "fixture_source_sha256": identity.fixture_fingerprint(fixture),
        "runner_sha256": identity.file_sha256(runner),
        "runner_path": str(runner),
        "fixture_root": str(fixture),
        "toolchain": "unit fixture",
        "configuration": "debug",
    }
    receipt = fixture / "build.json"
    receipt.write_text(json.dumps(value))
    return fixture, runner, receipt


@pytest.mark.parametrize("fault", ["binary", "fixture", "framework", "path", "executable", "kind"])
def test_consumer_prebuild_requires_actual_current_inputs(project, consumer, fault):
    fixture, runner, receipt = consumer
    assert identity.validate_consumer(project, runner, receipt)["kind"] == "consumer"
    if fault == "binary":
        runner.write_text("replaced executable")
    elif fault == "fixture":
        (fixture / "Sources/main.swift").write_text("different consumer")
    elif fault == "framework":
        (project / "Sources/new.swift").write_text("changed framework")
    elif fault == "executable":
        runner.chmod(0o600)
    else:
        value = json.loads(receipt.read_text())
        value["runner_path" if fault == "path" else "kind"] = "incorrect"
        receipt.write_text(json.dumps(value))
    with pytest.raises(ValueError):
        identity.validate_consumer(project, runner, receipt)


def test_atomic_identity_failure_preserves_previous_record(project, packaged, monkeypatch):
    path = packaged / identity.STAMP
    before = path.read_bytes()

    def fail(*args, **kwargs):
        raise OSError("unit injected replace failure")

    monkeypatch.setattr(os, "replace", fail)
    with pytest.raises(OSError):
        identity.stamp_app(project, packaged, identity.source_fingerprint(project), "debug", "new")
    assert path.read_bytes() == before
    assert not list(path.parent.glob(".build-identity-*"))
