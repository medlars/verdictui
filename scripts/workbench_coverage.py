"""Observe this product's actual Workbench and retain separately reviewed paint."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.util
import json
import os
import stat
import subprocess
import sys
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import workbench_identity as identity

SCOPE = ["workbench-connected-workflow"]
ROOT = Path(__file__).resolve().parents[1]
CRITERIA = {"alignment", "clipping", "contrast", "state-clarity", "motion-preference"}


def read_json(path: Path) -> dict[str, Any]:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 4 * 1024 * 1024:
            raise ValueError("evidence JSON unavailable or oversized")
        body = stream.read(4 * 1024 * 1024 + 1)
    if len(body) > 4 * 1024 * 1024:
        raise ValueError("evidence JSON grew beyond budget")
    value = json.loads(body)
    if not isinstance(value, dict):
        raise ValueError("evidence must be an object")
    return value


def shared_reader():
    location = Path(
        os.environ.get("VERDICTUI_PM_BASE_DIR", str(Path.home() / "Projects/shared-libs/pm-base"))
    )
    sys.path.insert(0, str(location))
    return importlib.import_module("ui_coverage")


def driver(root: Path):
    spec = importlib.util.spec_from_file_location(
        "workbench_acceptance", root / "scripts/workbench-acceptance.py"
    )
    if spec is None or spec.loader is None:
        raise ValueError("native acceptance driver unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def start(root: Path):
    """Invalidate prior evidence even if shared code or prebuilds are missing."""
    state = root / ".verdictui"
    if state.is_symlink():
        raise ValueError("coverage directory cannot be a symlink")
    relative = ".verdictui/coverage-attempt.json"
    ignored = subprocess.run(
        ["git", "-C", str(root), "check-ignore", "--", relative],
        capture_output=True,
        timeout=5,
        check=False,
    )
    if ignored.returncode != 0:
        raise ValueError("coverage attempt must be ignored and untracked")
    identity._write(
        state / "coverage-attempt.json",
        {
            "schema": 1,
            "id": str(uuid.uuid4()),
            "started_at": datetime.now(UTC).isoformat(),
            "status": "unavailable",
            "reason": "Workbench attempt initialization incomplete",
        },
    )
    shared = shared_reader()
    attempt = shared.begin_attempt(root)
    policy = read_json(state / "coverage.json")
    checks = read_json(state / "checks.json")
    if policy.get("scope") != SCOPE or checks != {
        "checks": [
            {
                "name": SCOPE[0],
                "kind": "web",
                "runner": ".verdictui/run-workbench.py",
                "subject": SCOPE[0],
            }
        ]
    }:
        raise ValueError("Workbench scope or checks changed")
    return shared, attempt


def evidence_parent(root: Path) -> Path:
    path = Path.home() / "Library/Application Support/VerdictUI/WorkbenchEvidence"
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError("evidence parent cannot contain symlinks")
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    info = path.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("evidence parent must be private")
    if path.resolve().is_relative_to(root):
        raise ValueError("evidence must be outside measured source")
    return path


def artifact(path: Path) -> dict[str, Any]:
    return {
        "root": str(path.parent),
        "path": str(path),
        "name": path.name,
        "size_bytes": path.stat().st_size,
        "sha256": identity.file_sha256(path),
    }


def current(root: Path, shared: Any, attempt: dict) -> None:
    if read_json(root / ".verdictui/coverage-attempt.json") != attempt:
        raise ValueError("newer Workbench attempt superseded this result")
    if (
        shared.source_subject(root) != attempt["source_subject"]
        or hashlib.sha256((root / ".verdictui/checks.json").read_bytes()).hexdigest()
        != attempt["checks_sha256"]
    ):
        raise ValueError("source or declarations changed during observation")


def validate_observation(root: Path, report: dict, run_root: Path, native: Any) -> None:
    native.validate_report(report, run_root)
    app = report["identities"]["app"]
    consumer = report["identities"]["consumer"]
    if (
        identity.validate_app(root, Path(app["app"])) != app
        or identity.validate_consumer(
            root, Path(consumer["runner_path"]), root / ".verdictui/workbench-consumer.json"
        )
        != consumer
    ):
        raise ValueError("native observation no longer matches current builds")


def dimension(shared: Any, run_root: Path, base: dict, kind: str, status: str, payload: dict):
    path = run_root / (kind + "-observation.json")
    shared.write_observation(
        path, {**base, "subject_kind": "product", "kind": kind, "status": status, **payload}
    )
    return {"kind": kind, "status": status, "scope": SCOPE, "artifact": artifact(path)}


def observe(root: Path = ROOT) -> tuple[bytes, Path]:
    root = root.resolve(strict=True)
    shared, attempt = start(root)
    output = evidence_parent(root) / attempt["id"]
    native = driver(root)
    output = native.create_output(output)
    try:
        inputs = read_json(root / "dist/workbench-acceptance-inputs.json")
        if type(inputs.get("schema")) is not int or inputs["schema"] != 1:
            raise ValueError("Workbench acceptance preparation unavailable")
        args = argparse.Namespace(
            app=Path(inputs["app"]),
            consumer_runner=Path(inputs["consumer_runner"]),
            consumer_build_receipt=Path(inputs["consumer_build_receipt"]),
            timeout_seconds=25,
        )
        if args.app.resolve() != (root / "dist/VerdictUI.app").resolve() or (
            args.consumer_build_receipt.resolve()
            != (root / ".verdictui/workbench-consumer.json").resolve()
        ):
            raise ValueError("preparation belongs to another project")
        report = native.run(args, root, output)
        native.save(output / "report.json", report)
        validate_observation(root, report, output, native)
        tree = native.artifact_bytes(output, report["final_tree"])
        helper = args.app / "Contents/Helpers/verdictui"
        judged = subprocess.run(
            [
                str(helper),
                "judge",
                str(output / report["final_tree"]["path"]),
                "--web",
                "--name",
                SCOPE[0],
            ],
            capture_output=True,
            timeout=10,
            check=False,
        )
        verdict = json.loads(judged.stdout)
        status = "pass" if judged.returncode == 0 else "fail"
        if (
            judged.returncode not in {0, 1}
            or verdict.get("status") != status.upper()
            or (not isinstance(verdict.get("findings"), list))
        ):
            raise ValueError("actual layout judgment unavailable")
        current(root, shared, attempt)
        base = {
            "schema": 1,
            "root": str(root),
            "scope": SCOPE,
            "attempt_id": attempt["id"],
            "source_subject": attempt["source_subject"],
            "checks_sha256": attempt["checks_sha256"],
            "observed_at": datetime.now(UTC).isoformat(),
        }
        report_artifact = artifact(output / "report.json")
        dimensions = {
            "layout": dimension(
                shared,
                output,
                base,
                "layout",
                status,
                {"verdict": verdict, "native_report": report_artifact},
            ),
            "behavior": dimension(
                shared,
                output,
                base,
                "behavior",
                "pass",
                {"native_report": report_artifact, "phases": report["phases"]},
            ),
            "paint": {"status": "unavailable"},
        }
        current(root, shared, attempt)
        shared.write_observation(
            root / ".verdictui/coverage-receipt.json",
            {**base, "native_report": report_artifact, "dimensions": dimensions},
        )
        return tree, output
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        ImportError,
        subprocess.SubprocessError,
    ) as error:
        identity._write(
            output / "unavailable.json", {"status": "unavailable", "reason": str(error)}
        )
        raise


def validate_review(review: dict, report: dict, report_hash: str) -> None:
    expected = {row["path"]: row["sha256"] for row in report["snapshots"]}
    reviewed = datetime.fromisoformat(review["reviewed_at"])
    if (
        review.get("verdict") != "pass"
        or review.get("scope") != SCOPE
        or review.get("run_id") != report["run_id"]
        or review.get("report_sha256") != report_hash
        or review.get("images") != expected
        or not isinstance(review.get("reviewer"), str)
        or not review["reviewer"].strip()
        or set(review.get("criteria", [])) != CRITERIA
        or reviewed.tzinfo is None
        or reviewed > datetime.now(UTC)
    ):
        raise ValueError("paint review must bind every actual image, phase, scope and criterion")


def publish_review(path: Path, root: Path = ROOT) -> None:
    root = root.resolve(strict=True)
    shared = shared_reader()
    attempt = read_json(root / ".verdictui/coverage-attempt.json")
    current(root, shared, attempt)
    receipt = read_json(root / ".verdictui/coverage-receipt.json")
    if receipt.get("attempt_id") != attempt["id"] or receipt.get("scope") != SCOPE:
        raise ValueError("review cannot certify an earlier attempt")
    report_descriptor = receipt["native_report"]
    report = json.loads(shared.read_artifact(report_descriptor, max_bytes=4 * 1024 * 1024))
    output = Path(report_descriptor["root"])
    native = driver(root)
    validate_observation(root, report, output, native)
    review = read_json(path)
    validate_review(review, report, report_descriptor["sha256"])
    base = {
        key: receipt[key]
        for key in (
            "schema",
            "root",
            "scope",
            "attempt_id",
            "source_subject",
            "checks_sha256",
            "observed_at",
        )
    }
    record = dimension(
        shared,
        output,
        base,
        "paint",
        "pass",
        {
            "native_report": report_descriptor,
            "review": review,
        },
    )
    final = next(row for row in report["snapshots"] if row["phase"] == "final")
    record["image"] = artifact(native.artifact(output, final))
    record["review"] = {**review, **base, "image_sha256": final["sha256"]}
    current(root, shared, attempt)
    receipt["dimensions"]["paint"] = record
    shared.write_observation(root / ".verdictui/coverage-receipt.json", receipt)


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    try:
        if args == ["list"]:
            print(json.dumps(SCOPE))
        elif args == ["render", SCOPE[0]]:
            tree, _ = observe()
            sys.stdout.buffer.write(tree)
        elif args == ["observe"]:
            _, output = observe()
            print(output / "report.json")
        elif len(args) == 2 and args[0] == "review":
            publish_review(Path(args[1]))
            print("Workbench paint review retained for the latest declared scope")
        else:
            raise ValueError(
                "use list, render workbench-connected-workflow, observe, or review PATH"
            )
        return 0
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        ImportError,
        subprocess.SubprocessError,
    ) as error:
        print(f"Workbench coverage unavailable: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
