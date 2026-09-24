"""A current workflow and independent paint review are both required."""

import hashlib
import json
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import workbench_coverage as coverage


@pytest.fixture
def root(tmp_path):
    root = tmp_path / "product"
    (root / ".verdictui").mkdir(parents=True)
    (root / ".gitignore").write_text(
        ".verdictui/coverage-attempt.json\n.verdictui/coverage-receipt.json\n"
    )
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    (root / ".verdictui/checks.json").write_text("{}")
    return root


def test_missing_shared_dependency_invalidates_previous_pass_first(root, monkeypatch):
    attempt_path = root / ".verdictui/coverage-attempt.json"
    attempt_path.write_text('{"id":"old-pass"}')

    def missing():
        raise ImportError("unit missing shared reader")

    monkeypatch.setattr(coverage, "shared_reader", missing)
    with pytest.raises(ImportError):
        coverage.observe(root)
    latest = json.loads(attempt_path.read_text())
    assert latest["id"] != "old-pass"
    assert latest["status"] == "unavailable"


def test_tracked_attempt_cannot_change_source_to_certify_itself(root):
    attempt_path = root / ".verdictui/coverage-attempt.json"
    attempt_path.write_text('{"id":"tracked"}')
    subprocess.run(["git", "-C", str(root), "add", "-f", str(attempt_path)], check=True)
    with pytest.raises(ValueError, match="ignored and untracked"):
        coverage.start(root)
    assert json.loads(attempt_path.read_text())["id"] == "tracked"


@pytest.fixture
def attempt(root):
    value = {
        "schema": 1,
        "id": "current-attempt",
        "source_subject": {"tree": "current"},
        "checks_sha256": hashlib.sha256((root / ".verdictui/checks.json").read_bytes()).hexdigest(),
    }
    (root / ".verdictui/coverage-attempt.json").write_text(json.dumps(value))
    return value


@pytest.mark.parametrize("fault", ["new-attempt", "source", "checks"])
def test_changed_inputs_or_superseding_attempt_refuse_publication(root, attempt, fault):
    shared = SimpleNamespace(source_subject=lambda _: {"tree": "current"})
    coverage.current(root, shared, attempt)
    if fault == "new-attempt":
        (root / ".verdictui/coverage-attempt.json").write_text('{"id":"new"}')
    elif fault == "source":
        shared.source_subject = lambda _: {"tree": "changed"}
    else:
        (root / ".verdictui/checks.json").write_text("changed declarations")
    with pytest.raises(ValueError):
        coverage.current(root, shared, attempt)


@pytest.fixture
def paint():
    # Identity admission is tested separately against real files; this exercises
    # the review-to-observation binding, including every required captured image.
    snapshots = [
        {"path": name + ".png", "sha256": str(index) * 64}
        for index, name in enumerate(
            (
                "connected",
                "pass",
                "fail",
                "running-before",
                "running-after",
                "history",
                "final",
                "compact",
            )
        )
    ]
    report = {"run_id": "actual-run", "snapshots": snapshots}
    review = {
        "verdict": "pass",
        "scope": coverage.SCOPE,
        "run_id": "actual-run",
        "report_sha256": "a" * 64,
        "reviewer": "independent unit fixture",
        "reviewed_at": datetime.now(UTC).isoformat(),
        "criteria": sorted(coverage.CRITERIA),
        "images": {row["path"]: row["sha256"] for row in snapshots},
    }
    return report, review


@pytest.mark.parametrize(
    "fault",
    [
        "missing-image",
        "changed-image",
        "unreviewed-compact",
        "report",
        "run",
        "scope",
        "failure",
        "criterion",
        "reviewer",
        "future",
        "timezone",
    ],
)
def test_paint_review_requires_all_actual_images_and_current_workflow(paint, fault):
    report, review = paint
    coverage.validate_review(review, report, "a" * 64)
    if fault == "missing-image":
        del review["images"]["running-after.png"]
    elif fault == "changed-image":
        report["snapshots"][0]["sha256"] = "f" * 64
    elif fault == "unreviewed-compact":
        del review["images"]["compact.png"]
    elif fault == "criterion":
        review["criteria"].remove("contrast")
    else:
        key, value = {
            "report": ("report_sha256", "b" * 64),
            "run": ("run_id", "other"),
            "scope": ("scope", ["whole-fleet"]),
            "failure": ("verdict", "fail"),
            "reviewer": ("reviewer", ""),
            "future": ("reviewed_at", "2999-01-01T00:00:00+00:00"),
            "timezone": ("reviewed_at", "2026-01-01T00:00:00"),
        }[fault]
        review[key] = value
    with pytest.raises(ValueError):
        coverage.validate_review(review, report, "a" * 64)


def test_current_native_report_is_revalidated_before_admission(tmp_path, monkeypatch):
    root = tmp_path
    report = {
        "identities": {
            "app": {"app": str(root / "App.app"), "sha": "current"},
            "consumer": {"runner_path": str(root / "runner"), "sha": "current"},
        }
    }
    called = []
    native = SimpleNamespace(validate_report=lambda *args: called.append(args))
    monkeypatch.setattr(
        coverage.identity, "validate_app", lambda *args: report["identities"]["app"]
    )
    monkeypatch.setattr(
        coverage.identity, "validate_consumer", lambda *args: report["identities"]["consumer"]
    )
    coverage.validate_observation(root, report, tmp_path, native)
    assert called == [(report, tmp_path)]
    monkeypatch.setattr(coverage.identity, "validate_app", lambda *args: {"sha": "replaced"})
    with pytest.raises(ValueError, match="current builds"):
        coverage.validate_observation(root, report, tmp_path, native)


@pytest.mark.parametrize("fault", ["symlink", "oversized", "nonobject"])
def test_evidence_json_requires_bounded_regular_object(tmp_path, fault):
    path = tmp_path / "record.json"
    if fault == "symlink":
        target = tmp_path / "target"
        target.write_text("{}")
        path.symlink_to(target)
    elif fault == "oversized":
        with path.open("wb") as stream:
            stream.truncate(4 * 1024 * 1024 + 1)
    else:
        path.write_text("[]")
    with pytest.raises((ValueError, OSError)):
        coverage.read_json(path)


def test_runner_missing_prebuild_never_emits_a_tree(root, monkeypatch, tmp_path, capsys):
    native = SimpleNamespace(create_output=lambda path: (path.mkdir(), path)[1])
    monkeypatch.setattr(coverage, "start", lambda _: (object(), {"id": "attempt"}))
    monkeypatch.setattr(coverage, "evidence_parent", lambda _: tmp_path)
    monkeypatch.setattr(coverage, "driver", lambda _: native)

    # Exercise observe directly with explicit root so no installed product is read.
    with pytest.raises(FileNotFoundError):
        coverage.observe(root)
    assert (tmp_path / "attempt/unavailable.json").is_file()
    assert capsys.readouterr().out == ""


@pytest.mark.parametrize("code,status", [(0, "pass"), (1, "fail"), (2, "unavailable")])
def test_observed_layout_failure_is_retained_and_paint_requires_review(
    root, attempt, tmp_path, monkeypatch, code, status
):
    inputs = root / "dist/workbench-acceptance-inputs.json"
    inputs.parent.mkdir()
    inputs.write_text(
        json.dumps(
            {
                "schema": 1,
                "app": str(root / "dist/VerdictUI.app"),
                "consumer_runner": str(root / "consumer"),
                "consumer_build_receipt": str(root / ".verdictui/workbench-consumer.json"),
            }
        )
    )
    shared = SimpleNamespace(
        write_observation=coverage.identity._write,
        source_subject=lambda _: attempt["source_subject"],
    )
    report = {
        "phases": [{"id": "unit-phase", "status": "pass"}],
        "final_tree": {"path": "tree.json"},
    }
    tree = b'{"id":"unit"}'
    native = SimpleNamespace(
        create_output=lambda path: (path.mkdir(), path)[1],
        run=lambda *args: report,
        save=coverage.identity._write,
        artifact_bytes=lambda *args: tree,
    )
    monkeypatch.setattr(coverage, "start", lambda _: (shared, attempt))
    monkeypatch.setattr(coverage, "evidence_parent", lambda _: tmp_path)
    monkeypatch.setattr(coverage, "driver", lambda _: native)
    validated = []
    monkeypatch.setattr(coverage, "validate_observation", lambda *args: validated.append(args))

    def judge(args, **kwargs):
        assert args[1] == "judge" and "--web" in args
        assert kwargs["timeout"] == 10
        return subprocess.CompletedProcess(
            args,
            code,
            json.dumps(
                {
                    "status": status.upper(),
                    "findings": [] if code == 0 else [{"severity": "error"}],
                }
            ).encode(),
            b"",
        )

    monkeypatch.setattr(coverage.subprocess, "run", judge)
    if code == 2:
        with pytest.raises(ValueError, match="layout judgment unavailable"):
            coverage.observe(root)
        assert not (root / ".verdictui/coverage-receipt.json").exists()
    else:
        actual, output = coverage.observe(root)
        assert actual == tree and validated
        receipt = coverage.read_json(root / ".verdictui/coverage-receipt.json")
        assert receipt["dimensions"]["layout"]["status"] == status
        assert receipt["dimensions"]["behavior"]["status"] == "pass"
        assert receipt["dimensions"]["paint"]["status"] == "unavailable"
        assert coverage.read_json(output / "layout-observation.json")["status"] == status
