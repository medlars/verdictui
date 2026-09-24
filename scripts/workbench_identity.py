"""Bind packaged Workbench and prebuilt consumer evidence to actual build inputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

MAX_BYTES = 256 * 1024 * 1024
MAX_FILES = 100_000
DEADLINE_SECONDS = 10
STAMP = Path("Contents/Resources/WorkbenchBuild.json")
RESOURCE_ROOT = Path(
    "Contents/Resources/VerdictUI_VerdictUIWorkbench.bundle/Contents/Resources/Resources"
)


def _digest_paths(root: Path, paths: list[Path]) -> str:
    """Read bounded regular files, including ignored SwiftPM inputs, without symlinks."""
    deadline = time.monotonic() + DEADLINE_SECONDS
    total = 0
    count = 0
    files = 0
    digest = hashlib.sha256()

    def reserve_entry() -> None:
        nonlocal count
        count += 1
        if count > MAX_FILES or time.monotonic() > deadline:
            raise ValueError("build input scan exceeded entry budget or deadline")

    def visit(path: Path) -> None:
        nonlocal files, total
        if time.monotonic() > deadline:
            raise ValueError("build input scan exceeded deadline")
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise ValueError("build input symlink refused")
        if stat.S_ISDIR(info.st_mode):
            children: list[Path] = []
            with os.scandir(path) as entries:
                for entry in entries:
                    reserve_entry()
                    children.append(Path(entry.path))
            for child in sorted(children):
                visit(child)
            return
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("build input is not a regular file")
        files += 1
        total += info.st_size
        if total > MAX_BYTES:
            raise ValueError("build input scan exceeded budget")
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            before = os.fstat(stream.fileno())
            if (before.st_dev, before.st_ino, before.st_size) != (
                info.st_dev,
                info.st_ino,
                info.st_size,
            ) or not stat.S_ISREG(before.st_mode):
                raise ValueError("build input changed during scan")
            body = stream.read(MAX_BYTES - total + info.st_size + 1)
            after = os.fstat(stream.fileno())
        if len(body) != info.st_size or (before.st_size, before.st_mtime_ns) != (
            after.st_size,
            after.st_mtime_ns,
        ):
            raise ValueError("build input changed during scan")
        relative = path.relative_to(root).as_posix().encode()
        digest.update(len(relative).to_bytes(8, "big") + relative)
        digest.update(len(body).to_bytes(8, "big") + body)

    for path in paths:
        reserve_entry()
        visit(path)
    if not files or time.monotonic() > deadline:
        raise ValueError("build input scan empty or expired")
    return digest.hexdigest()


def source_fingerprint(root: Path) -> str:
    root = root.resolve(strict=True)
    return _digest_paths(
        root,
        [
            root / name
            for name in (
                "Package.swift",
                "Package.resolved",
                "Sources",
                "assets",
                "scripts/build-workbench.sh",
                "scripts/workbench_identity.py",
            )
        ],
    )


def fixture_fingerprint(root: Path) -> str:
    root = root.resolve(strict=True)
    # Build outputs and runtime declarations are deliberately not source inputs.
    return _digest_paths(
        root, [root / "Package.swift", root / "Package.resolved", root / "Sources"]
    )


def file_sha256(path: Path) -> str:
    deadline = time.monotonic() + DEADLINE_SECONDS
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_BYTES:
            raise ValueError("artifact is not regular or exceeds byte budget")
        digest = hashlib.sha256()
        total = 0
        while body := stream.read(1024 * 1024):
            total += len(body)
            if total > MAX_BYTES or time.monotonic() > deadline:
                raise ValueError("artifact hash exceeded budget or deadline")
            digest.update(body)
        after = os.fstat(stream.fileno())
    if (before.st_size, before.st_mtime_ns) != (
        after.st_size,
        after.st_mtime_ns,
    ) or total != before.st_size:
        raise ValueError("artifact changed while hashing")
    return digest.hexdigest()


def _json(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 64 * 1024:
        raise ValueError("build identity missing or oversized")
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or type(value.get("schema")) is not int or value["schema"] != 1:
        raise ValueError("invalid build identity schema")
    return value


def _write(path: Path, value: dict[str, Any]) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=".build-identity-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, sort_keys=True, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def stamp_app(root: Path, app: Path, before: str, configuration: str, toolchain: str) -> None:
    if source_fingerprint(root) != before:
        raise ValueError("Workbench source changed while building")
    _write(
        app / STAMP,
        {
            "schema": 1,
            "kind": "workbench",
            "framework_source_sha256": before,
            "configuration": configuration,
            "toolchain": toolchain,
        },
    )


def validate_app(root: Path, app: Path) -> dict[str, Any]:
    root = root.resolve(strict=True)
    app = app.resolve(strict=True)
    receipt = _json(app / STAMP)
    if receipt.get("kind") != "workbench" or receipt.get(
        "framework_source_sha256"
    ) != source_fingerprint(root):
        raise ValueError("Workbench prebuild does not match current source")
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
        check=True,
        capture_output=True,
        timeout=15,
    )
    resources = root / "Sources/VerdictUIWorkbench/Resources"
    actual_resources = app / RESOURCE_ROOT
    if _digest_paths(resources, [resources]) != _digest_paths(actual_resources, [actual_resources]):
        raise ValueError("packaged Workbench resources do not match current source")
    binary = app / "Contents/MacOS/VerdictUIWorkbench"
    helper = app / "Contents/Helpers/verdictui"
    if not os.access(binary, os.X_OK) or not os.access(helper, os.X_OK):
        raise ValueError("Workbench or helper is not executable")
    return {
        **receipt,
        "app": str(app),
        "binary_sha256": file_sha256(binary),
        "helper_sha256": file_sha256(helper),
        "stamp_sha256": file_sha256(app / STAMP),
    }


def validate_consumer(root: Path, runner: Path, receipt: Path) -> dict[str, Any]:
    value = _json(receipt)
    if value.get("kind") != "consumer" or value.get(
        "framework_source_sha256"
    ) != source_fingerprint(root):
        raise ValueError("consumer prebuild does not match current framework source")
    if value.get("runner_path") != str(runner.resolve(strict=True)) or value.get(
        "runner_sha256"
    ) != file_sha256(runner):
        raise ValueError("consumer runner identity mismatch")
    if not os.access(runner, os.X_OK):
        raise ValueError("consumer runner is not executable")
    fixture = Path(value["fixture_root"])
    if value.get("fixture_source_sha256") != fixture_fingerprint(fixture):
        raise ValueError("consumer fixture source changed")
    if value.get("fixture_template_sha256") != fixture_fingerprint(root / "examples/ConsumerApp"):
        raise ValueError("canonical consumer template changed")
    return value


def prepare_consumer(root: Path, fixture: Path) -> None:
    """Prepare a distinct real consumer package; never overwrite another build."""
    root = root.resolve(strict=True)
    source = root / "examples/ConsumerApp"
    template_before = fixture_fingerprint(source)
    package = (source / "Package.swift").read_text()
    needle = 'path: "../.."'
    if package.count(needle) != 1:
        raise ValueError("consumer fixture dependency declaration changed")
    fixture.mkdir(mode=0o700)
    (fixture / "Package.swift").write_text(
        package.replace(needle, "path: " + json.dumps(str(root), ensure_ascii=False))
    )
    shutil.copytree(source / "Sources", fixture / "Sources", symlinks=True)
    shutil.copyfile(source / "Package.resolved", fixture / "Package.resolved")
    if fixture_fingerprint(source) != template_before:
        raise ValueError("canonical consumer template changed during preparation")
    _write(
        fixture / "build-inputs.json",
        {
            "schema": 1,
            "kind": "consumer-inputs",
            "framework_source_sha256": source_fingerprint(root),
            "fixture_source_sha256": fixture_fingerprint(fixture),
            "fixture_template_sha256": template_before,
        },
    )


def stamp_consumer(root: Path, fixture: Path, runner: Path, output: Path, toolchain: str) -> None:
    before = _json(fixture / "build-inputs.json")
    if before.get("kind") != "consumer-inputs" or before.get(
        "framework_source_sha256"
    ) != source_fingerprint(root):
        raise ValueError("framework changed while consumer was building")
    if before.get("fixture_source_sha256") != fixture_fingerprint(fixture):
        raise ValueError("consumer source changed while building")
    if before.get("fixture_template_sha256") != fixture_fingerprint(root / "examples/ConsumerApp"):
        raise ValueError("canonical consumer template changed while building")
    if not os.access(runner, os.X_OK):
        raise ValueError("built consumer is not executable")
    _write(
        output,
        {
            **before,
            "kind": "consumer",
            "runner_path": str(runner.resolve(strict=True)),
            "runner_sha256": file_sha256(runner),
            "fixture_root": str(fixture.resolve(strict=True)),
            "configuration": "debug",
            "toolchain": toolchain,
        },
    )


def acceptance_inputs(root: Path, app: Path, runner: Path, receipt: Path, output: Path) -> None:
    """Publish discovery only after both real build identities validate."""
    validate_app(root, app)
    validate_consumer(root, runner, receipt)
    _write(
        output,
        {
            "schema": 1,
            "app": str(app.resolve(strict=True)),
            "consumer_runner": str(runner.resolve(strict=True)),
            "consumer_build_receipt": str(receipt.resolve(strict=True)),
        },
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "operation",
        choices=(
            "fingerprint",
            "stamp",
            "validate",
            "prepare-consumer",
            "stamp-consumer",
            "inputs",
        ),
    )
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--before")
    parser.add_argument("--configuration", choices=("debug", "release"))
    parser.add_argument("--toolchain")
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--runner", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    if args.operation == "fingerprint":
        print(source_fingerprint(args.root))
    elif args.operation == "prepare-consumer":
        if not args.fixture:
            parser.error("prepare-consumer requires fixture")
        prepare_consumer(args.root, args.fixture)
    elif args.operation == "stamp-consumer":
        if not args.fixture or not args.runner or not args.output or not args.toolchain:
            parser.error("stamp-consumer requires fixture, runner, output and toolchain")
        stamp_consumer(args.root, args.fixture, args.runner, args.output, args.toolchain)
    elif args.operation == "inputs":
        if not args.app or not args.runner or not args.receipt or not args.output:
            parser.error("inputs requires app, runner, receipt and output")
        acceptance_inputs(args.root, args.app, args.runner, args.receipt, args.output)
    elif args.operation == "stamp":
        if not args.app or not args.before or not args.configuration or not args.toolchain:
            parser.error("stamp requires app, before, configuration and toolchain")
        stamp_app(args.root, args.app, args.before, args.configuration, args.toolchain)
    elif args.app:
        print(json.dumps(validate_app(args.root, args.app)))
    else:
        parser.error("validate requires app")


if __name__ == "__main__":
    main()
