#!/usr/bin/env python3.14
"""Contract validation for VerdictUI.

Run: python3.14 contracts/validate-contracts.py

Three fail-closed checks over the verdict wire format:

1. **Schema integrity** — `verdict-schema.json` parses, every `$ref` resolves, and
   it uses only keywords this validator implements.
2. **Version agreement** — the schema's declared version matches
   `SchemaVersion.current` in the Swift kernel. `SchemaVersion.swift`'s own doc
   comment promises this check exists; this is where it is kept.
3. **Fixture round-trip** — every payload under `contracts/fixtures/` (produced by
   `Verdict.encode(to:)`, kept in step with it by `ContractFixtureTests`)
   validates against the schema. That closes the loop: the Swift encoder's real
   output is checked against the contract the CLI and MCP consumers read.

Why a hand-rolled validator instead of `jsonschema`: this repo is deliberately
never pip-installed (ADR 2026-003) and declares no Python runtime dependencies,
so an `import jsonschema` would be a soft dependency — and a validator that skips
its work when a library is missing is worse than no validator, because it reports
PASS. The implemented subset of draft 2020-12 is exactly what the schema uses;
`unsupported_keywords()` fails the run if the schema ever grows a keyword the
subset does not cover, so the gap can never be silent.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any, Callable

CONTRACTS = Path(__file__).resolve().parent
SCHEMA_NAME = "verdict-schema.json"
FIXTURE_DIR_NAME = "fixtures"
KERNEL_SCHEMA_VERSION_SOURCE = (
    CONTRACTS.parent / "Sources" / "VerdictUIKernel" / "SchemaVersion.swift"
)

# `public static let current = "1.0"` — the one declaration the drift check reads.
_SWIFT_CURRENT_RE = re.compile(r'static\s+let\s+current\s*=\s*"([^"]+)"')

# Keywords with no effect on validation: documentation and identity only.
ANNOTATION_KEYWORDS = frozenset({"$schema", "$id", "title", "description", "$comment"})

# Named because it appears in the keyword set, the schema walk, and the object
# check, and a typo in any one of the three would silently stop enforcing it.
ADDITIONAL_PROPERTIES = "additionalProperties"
DEFS = "$defs"
ITEMS = "items"
PROPERTIES = "properties"
REF = "$ref"

# Keywords this validator actually enforces. Anything outside these two sets is
# treated as an unimplemented keyword and fails the run.
ASSERTION_KEYWORDS = frozenset(
    {
        REF,
        DEFS,
        "type",
        "const",
        "enum",
        "required",
        PROPERTIES,
        ADDITIONAL_PROPERTIES,
        ITEMS,
        "minItems",
        "minLength",
        "minimum",
        "pattern",
    }
)

_TYPE_PREDICATES: dict[str, Callable[[Any], bool]] = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    # bool is an int subclass in Python; JSON Schema keeps them distinct.
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}

__all__ = [
    "ANNOTATION_KEYWORDS",
    "ASSERTION_KEYWORDS",
    "CONTRACTS",
    "SchemaError",
    "main",
    "resolve",
    "unsupported_keywords",
    "validate",
]


class SchemaError(Exception):
    """The schema itself is unusable — distinct from an instance failing it."""


# ── Schema integrity ────────────────────────────────────────────────────────────


def resolve(schema: dict, root: dict) -> dict:
    """Follow a local `$ref`, raising ``SchemaError`` if it cannot be resolved.

    Only `#/$defs/<name>` is supported: that is the single form the contract uses,
    and silently ignoring any other pointer would validate against nothing.
    """
    ref = schema[REF]
    prefix = f"#/{DEFS}/"
    if not ref.startswith(prefix):
        raise SchemaError(f"unsupported $ref {ref!r} — only {prefix}<name> is implemented")
    name = ref[len(prefix) :]
    target = root.get("$defs", {}).get(name)
    if not isinstance(target, dict):
        raise SchemaError(f"$ref {ref!r} does not resolve to a schema")
    return target


def unsupported_keywords(schema: Any, path: str = "#") -> list[str]:
    """Every keyword in `schema` this validator would ignore rather than enforce.

    A non-empty result must fail the run: an unenforced keyword means the contract
    says more than the gate checks, and the gap would be invisible.
    """
    if not isinstance(schema, dict):
        return []
    found: list[str] = []
    for key, value in schema.items():
        if key in ANNOTATION_KEYWORDS:
            continue
        if key not in ASSERTION_KEYWORDS:
            found.append(f"{path}/{key}")
            continue
        if key in (PROPERTIES, DEFS) and isinstance(value, dict):
            for name, sub in value.items():
                found += unsupported_keywords(sub, f"{path}/{key}/{name}")
        elif key in (ITEMS, ADDITIONAL_PROPERTIES):
            found += unsupported_keywords(value, f"{path}/{key}")
    return found


# ── Instance validation (subset of draft 2020-12) ───────────────────────────────


def _check_type(value: Any, expected: Any, path: str, errors: list[str]) -> None:
    names = [expected] if isinstance(expected, str) else list(expected)
    for name in names:
        if name not in _TYPE_PREDICATES:
            raise SchemaError(f"unknown type {name!r} at {path}")
    if not any(_TYPE_PREDICATES[name](value) for name in names):
        errors.append(f"{path}: expected type {'|'.join(names)}, got {type(value).__name__}")


def _check_object(value: dict, schema: dict, root: dict, path: str, errors: list[str]) -> None:
    for name in schema.get("required", []):
        if name not in value:
            errors.append(f"{path}: missing required property {name!r}")
    properties = schema.get(PROPERTIES, {})
    extra = schema.get(ADDITIONAL_PROPERTIES, True)
    for name, member in value.items():
        if name in properties:
            validate(member, properties[name], root, f"{path}/{name}", errors)
        elif extra is False:
            errors.append(f"{path}: unexpected property {name!r}")
        elif isinstance(extra, dict):
            validate(member, extra, root, f"{path}/{name}", errors)


def _check_array(value: list, schema: dict, root: dict, path: str, errors: list[str]) -> None:
    minimum = schema.get("minItems")
    if minimum is not None and len(value) < minimum:
        errors.append(f"{path}: expected at least {minimum} item(s), got {len(value)}")
    item_schema = schema.get("items")
    if isinstance(item_schema, dict):
        for index, item in enumerate(value):
            validate(item, item_schema, root, f"{path}[{index}]", errors)


def _check_scalars(value: Any, schema: dict, path: str, errors: list[str]) -> None:
    if isinstance(value, str):
        minimum_length = schema.get("minLength")
        if minimum_length is not None and len(value) < minimum_length:
            errors.append(f"{path}: shorter than minLength {minimum_length}")
        pattern = schema.get("pattern")
        if pattern is not None and re.search(pattern, value) is None:
            errors.append(f"{path}: {value!r} does not match {pattern}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        minimum = schema.get("minimum")
        if minimum is not None and value < minimum:
            errors.append(f"{path}: {value} is below minimum {minimum}")


def validate(
    value: Any, schema: dict, root: dict, path: str = "$", errors: list[str] | None = None
) -> list[str]:
    """Collect every way `value` violates `schema`. Empty list means valid.

    Errors accumulate rather than short-circuiting so one run reports the whole
    picture of a broken fixture instead of its first symptom.
    """
    collected = [] if errors is None else errors
    if REF in schema:
        schema = resolve(schema, root)
    if "type" in schema:
        _check_type(value, schema["type"], path, collected)
    if "const" in schema and value != schema["const"]:
        collected.append(f"{path}: expected const {schema['const']!r}, got {value!r}")
    if "enum" in schema and value not in schema["enum"]:
        collected.append(f"{path}: {value!r} is not one of {schema['enum']}")
    if isinstance(value, dict):
        _check_object(value, schema, root, path, collected)
    elif isinstance(value, list):
        _check_array(value, schema, root, path, collected)
    else:
        _check_scalars(value, schema, path, collected)
    return collected


# ── Checks ──────────────────────────────────────────────────────────────────────


def _declared_version(schema: dict) -> str:
    """The version the schema pins, read from `properties.schemaVersion.const`."""
    try:
        declared = schema["properties"]["schemaVersion"]["const"]
    except (KeyError, TypeError) as exc:
        raise SchemaError(f"schema does not pin properties.schemaVersion.const ({exc})") from exc
    if not isinstance(declared, str):
        raise SchemaError(f"declared schemaVersion is {type(declared).__name__}, not a string")
    return declared


def _kernel_version(source: Path) -> str:
    """`SchemaVersion.current` as written in the Swift kernel."""
    match = _SWIFT_CURRENT_RE.search(source.read_text())
    if match is None:
        raise SchemaError(f"no 'static let current' declaration in {source}")
    return match.group(1)


def _check_version_agreement(schema: dict, source: Path, failures: list[str]) -> None:
    declared = _declared_version(schema)
    kernel = _kernel_version(source)
    if declared != kernel:
        failures.append(
            f"version drift: {SCHEMA_NAME} pins {declared!r} but "
            f"SchemaVersion.current is {kernel!r} — bump both or neither"
        )
        return
    # The $id carries the version too; a stale one misroutes consumers that fetch
    # the schema by URL.
    identifier = schema.get("$id", "")
    if declared not in identifier:
        failures.append(f"version drift: $id {identifier!r} does not carry version {declared!r}")
        return
    print(f"PASS: schema and SchemaVersion.current agree on {declared}")


def _check_fixtures(schema: dict, fixture_dir: Path, failures: list[str]) -> None:
    if not fixture_dir.is_dir():
        failures.append(f"no fixture directory at {fixture_dir} — nothing round-tripped")
        return
    fixtures = sorted(fixture_dir.glob("*.json"))
    if not fixtures:
        failures.append(f"{fixture_dir} holds no fixtures — nothing round-tripped")
        return
    for fixture in fixtures:
        try:
            payload = json.loads(fixture.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            failures.append(f"{fixture.name} unreadable: {exc}")
            continue
        errors = validate(payload, schema, schema, f"{fixture.name}")
        if errors:
            failures.append(f"{fixture.name} violates the schema: " + "; ".join(errors[:10]))
        else:
            print(f"PASS: {fixture.name} round-trips against {SCHEMA_NAME}")


def _load_schema(path: Path, failures: list[str]) -> dict | None:
    try:
        schema = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        failures.append(f"{path.name} unreadable: {exc}")
        return None
    if not isinstance(schema, dict):
        failures.append(f"{path.name} is a {type(schema).__name__}, not a schema object")
        return None
    unsupported = unsupported_keywords(schema)
    if unsupported:
        failures.append(
            "validator does not implement: "
            + ", ".join(unsupported)
            + " — extend validate-contracts.py rather than leaving the keyword unchecked"
        )
        return None
    print(f"PASS: {path.name} parses and uses only implemented keywords")
    return schema


def main(argv: Sequence[str] = ()) -> int:
    """Run all three checks. `argv` defaults to empty rather than ``sys.argv``, so an
    in-process caller (the PM stage, the tests) cannot accidentally inherit the
    host process's arguments.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--contracts",
        type=Path,
        default=CONTRACTS,
        help="directory holding verdict-schema.json and fixtures/",
    )
    parser.add_argument(
        "--kernel-source",
        type=Path,
        default=KERNEL_SCHEMA_VERSION_SOURCE,
        help="Swift file declaring SchemaVersion.current",
    )
    args = parser.parse_args(list(argv))

    schema_path = args.contracts / SCHEMA_NAME
    if not schema_path.exists():
        print(f"FAIL: {schema_path} not found — the verdict contract is pinned as of Wave 1")
        return 1

    failures: list[str] = []
    schema = _load_schema(schema_path, failures)
    if schema is not None:
        try:
            _check_version_agreement(schema, args.kernel_source, failures)
            _check_fixtures(schema, args.contracts / FIXTURE_DIR_NAME, failures)
        except (SchemaError, OSError) as exc:
            failures.append(str(exc))

    for failure in failures:
        print(f"FAIL: {failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
