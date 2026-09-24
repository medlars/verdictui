"""Bind packaged Workbench and prebuilt consumer evidence to actual build inputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
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
    digest = hashlib.sha256()

    def visit(path: Path) -> None:
        nonlocal count, total
        if time.monotonic() > deadline:
            raise ValueError("build input scan exceeded deadline")
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise ValueError("build input symlink refused")
        if stat.S_ISDIR(info.st_mode):
            for child in sorted(path.iterdir()):
                visit(child)
            return
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("build input is not a regular file")
        count += 1
        total += info.st_size
        if count > MAX_FILES or total > MAX_BYTES:
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
        visit(path)
    if not count or time.monotonic() > deadline:
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
    return _digest_paths(root, [root / "Package.swift", root / "Sources"])


def file_sha256(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise ValueError("artifact must be a regular file")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


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
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("fingerprint", "stamp", "validate"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--before")
    parser.add_argument("--configuration", choices=("debug", "release"))
    parser.add_argument("--toolchain")
    args = parser.parse_args()
    if args.operation == "fingerprint":
        print(source_fingerprint(args.root))
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
