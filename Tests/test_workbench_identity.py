"""Stale source, replaced binaries and missing builds cannot certify current UI."""

import json
import os
import shutil
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


def test_flat_swiftpm_resources_are_validated(project, packaged):
    flat = packaged / "Contents/Resources/VerdictUI_VerdictUIWorkbench.bundle/Resources"
    (packaged / identity.RESOURCE_ROOT).rename(flat)
    assert identity.validate_app(project, packaged)["resource_root"] == str(flat)
    (flat / "index.html").write_text("substituted flat resources")
    with pytest.raises(ValueError, match="resources"):
        identity.validate_app(project, packaged)


def test_two_packaged_resource_roots_are_ambiguous(project, packaged):
    flat = packaged / "Contents/Resources/VerdictUI_VerdictUIWorkbench.bundle/Resources"
    shutil.copytree(packaged / identity.RESOURCE_ROOT, flat)
    with pytest.raises(ValueError, match="ambiguous"):
        identity.validate_app(project, packaged)


def test_packaged_resource_parent_cannot_redirect_outside_app(project, packaged, tmp_path):
    parent = (packaged / identity.RESOURCE_ROOT).parent
    external = tmp_path / "redirected-resources"
    parent.rename(external)
    parent.symlink_to(external, target_is_directory=True)
    with pytest.raises(ValueError):
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
def consumer(project, tmp_path, consumer_source):
    fixture = tmp_path / "fixture"
    (fixture / "Sources").mkdir(parents=True)
    (fixture / "Package.swift").write_text("unit package")
    (fixture / "Package.resolved").write_text("pinned unit dependencies")
    (fixture / "Sources/main.swift").write_text("unit consumer")
    runner = fixture / "runner"
    runner.write_text("unit executable")
    runner.chmod(0o700)
    value = {
        "schema": 1,
        "kind": "consumer",
        "framework_source_sha256": identity.source_fingerprint(project),
        "fixture_source_sha256": identity.fixture_fingerprint(fixture),
        "fixture_template_sha256": identity.fixture_fingerprint(consumer_source),
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


@pytest.fixture
def consumer_source(project):
    source = project / "examples/ConsumerApp"
    (source / "Sources").mkdir(parents=True)
    (source / "Package.swift").write_text(
        'dependencies: [.package(name: "VerdictUI", path: "../..")]'
    )
    (source / "Package.resolved").write_text("pinned unit dependencies")
    (source / "Sources/main.swift").write_text("real fixture source bytes")
    return source


def test_preparation_keeps_pinned_sources_and_never_overwrites_existing_build(
    project, consumer_source, tmp_path
):
    fixture = tmp_path / "consumer"
    identity.prepare_consumer(project, fixture)
    assert (fixture / "Sources/main.swift").read_bytes() == (
        consumer_source / "Sources/main.swift"
    ).read_bytes()
    assert (fixture / "Package.resolved").read_bytes() == (
        consumer_source / "Package.resolved"
    ).read_bytes()
    assert json.dumps(str(project), ensure_ascii=False) in (fixture / "Package.swift").read_text()
    with pytest.raises(FileExistsError):
        identity.prepare_consumer(project, fixture)


@pytest.mark.parametrize("changed", ["framework", "fixture", "lock", "dependency"])
def test_preparation_and_stamp_reject_changed_build_inputs(
    project, consumer_source, tmp_path, changed
):
    fixture = tmp_path / "consumer"
    if changed == "dependency":
        (consumer_source / "Package.swift").write_text('path: "another-source"')
        with pytest.raises(ValueError, match="dependency"):
            identity.prepare_consumer(project, fixture)
        assert not fixture.exists()
        return
    identity.prepare_consumer(project, fixture)
    runner = fixture / "runner"
    runner.write_text("unit executable")
    runner.chmod(0o700)
    output = tmp_path / "receipt.json"
    identity.stamp_consumer(project, fixture, runner, output, "unit fixture")
    assert identity.validate_consumer(project, runner, output)["kind"] == "consumer"
    original = output.read_bytes()
    changed_path = (
        project / "Sources/new.swift"
        if changed == "framework"
        else fixture / "Sources/main.swift"
        if changed == "fixture"
        else fixture / "Package.resolved"
    )
    changed_path.write_text("changed after compilation began")
    with pytest.raises(ValueError, match="changed while"):
        identity.stamp_consumer(project, fixture, runner, output, "unit fixture")
    assert output.read_bytes() == original


def test_changed_canonical_consumer_invalidates_old_copied_runner(
    project, consumer_source, tmp_path
):
    fixture = tmp_path / "consumer"
    identity.prepare_consumer(project, fixture)
    runner = fixture / "runner"
    runner.write_text("unit executable")
    runner.chmod(0o700)
    receipt = tmp_path / "receipt.json"
    identity.stamp_consumer(project, fixture, runner, receipt, "unit fixture")
    (consumer_source / "Sources/main.swift").write_text("new acceptance contract")
    with pytest.raises(ValueError, match="template"):
        identity.validate_consumer(project, runner, receipt)


def test_directory_entries_count_against_scan_budget(project, monkeypatch):
    for index in range(8):
        (project / "Sources" / f"ignored-directory-{index}").mkdir()
    monkeypatch.setattr(identity, "MAX_FILES", 3)
    with pytest.raises(ValueError, match="budget"):
        identity._digest_paths(project, [project / "Sources"])


def test_artifact_hashing_refuses_oversized_bytes(tmp_path, monkeypatch):
    artifact = tmp_path / "large-binary"
    artifact.write_bytes(b"too many bytes")
    monkeypatch.setattr(identity, "MAX_BYTES", 4)
    with pytest.raises(ValueError, match="budget"):
        identity.file_sha256(artifact)


@pytest.mark.parametrize("changed", ["app", "consumer"])
def test_discovery_manifest_requires_both_current_builds(
    project, packaged, consumer, tmp_path, changed
):
    _, runner, receipt = consumer
    output = tmp_path / "inputs.json"
    identity.acceptance_inputs(project, packaged, runner, receipt, output)
    before = output.read_bytes()
    assert json.loads(before) == {
        "schema": 1,
        "app": str(packaged),
        "consumer_runner": str(runner),
        "consumer_build_receipt": str(receipt),
    }
    if changed == "app":
        (packaged / identity.RESOURCE_ROOT / "index.html").write_text("stale paint")
    else:
        runner.write_text("different consumer executable")
    with pytest.raises(ValueError):
        identity.acceptance_inputs(project, packaged, runner, receipt, output)
    assert output.read_bytes() == before
