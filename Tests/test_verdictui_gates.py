"""Tests for `floor-check.py` and `contracts/validate-contracts.py`.

Split out of `test_verdictui_pm.py` (CTS-E51CBEEB): both are standalone gate
SCRIPTS the PM shells out to, not PM stages, so they share nothing with the
stage tests but the loader preamble — which now lives in `pm_test_support.py`
so neither file can drift from the other's idea of how the PM is loaded.
"""

import contextlib
import importlib.util
import io
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest
from pm_test_support import _PROJECT_ROOT, _PYTHON, _needs_dev_machine

# Quick gate: pure-python, sub-second — belongs in the pre-merge gate.
# Without a marker the quick gate selects ZERO tests and reports success (lesson 183).
pytestmark = pytest.mark.quick


class TestFloorCheckFunction:
    """floor-check.py's check() helper appends to GAPS only for missing paths."""

    @staticmethod
    def _load_floor_check():
        fc_path = str(_PROJECT_ROOT / "scripts" / "floor-check.py")
        spec = importlib.util.spec_from_file_location("verdictui_floor_check", fc_path)
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        # Script style: module body runs all checks then sys.exit()s.
        try:
            spec.loader.exec_module(mod)  # type: ignore[union-attr]
        except SystemExit:
            pass
        return mod

    def test_check_records_gap_for_missing_path(self) -> None:
        mod = self._load_floor_check()
        before = len(mod.GAPS)
        assert mod.check("does/not/exist.xyz", "phantom") is False
        assert len(mod.GAPS) == before + 1
        assert mod.GAPS[-1]["item"] == "phantom"

    def test_check_passes_for_existing_path(self) -> None:
        mod = self._load_floor_check()
        before = len(mod.GAPS)
        assert mod.check("README.md", "readme") is True
        assert len(mod.GAPS) == before


def _load_validator():  # noqa: ANN202 — module object, hyphenated filename
    """Import contracts/validate-contracts.py, whose filename is not an identifier."""
    vc_path = str(_PROJECT_ROOT / "contracts" / "validate-contracts.py")
    spec = importlib.util.spec_from_file_location("verdictui_validate_contracts", vc_path)
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


class TestValidateContractsMain:
    def test_main_returns_zero(self) -> None:
        assert _load_validator().main() == 0


class TestFloorCheck:
    @_needs_dev_machine
    def test_floor_check_reports_zero_gaps(self) -> None:
        r = subprocess.run(
            [_PYTHON, str(_PROJECT_ROOT / "scripts" / "floor-check.py"), "--json"],
            capture_output=True,
            text=True,
            timeout=120,
        )
        import json

        payload = json.loads(r.stdout)
        assert payload["total"] == 0, f"floor gaps: {payload['gaps']}"
        assert r.returncode == 0


class TestValidateContracts:
    def test_validate_contracts_validates_the_pinned_schema(self) -> None:
        """Asserted PASS, not SKIP: SKIP was only correct while no schema existed.

        Wave 1 Task 5 pinned contracts/verdict-schema.json, so the validator now
        takes its real branch. The old assertion described a transitional state
        and started failing the moment the file it was waiting for arrived.
        """
        schema = _PROJECT_ROOT / "contracts" / "verdict-schema.json"
        assert schema.exists(), "schema is pinned as of Wave 1 Task 5"
        r = subprocess.run(
            [_PYTHON, str(_PROJECT_ROOT / "contracts" / "validate-contracts.py")],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert r.returncode == 0, r.stdout + r.stderr
        assert "PASS" in r.stdout, r.stdout
        assert "verdict-schema.json" in r.stdout, r.stdout

    def test_real_fixtures_are_actually_round_tripped(self) -> None:
        """The happy path above would also pass if the validator checked nothing.

        This asserts the work was done: one PASS line per committed fixture, and
        at least one fixture exists to round-trip.
        """
        fixtures = sorted((_PROJECT_ROOT / "contracts" / "fixtures").glob("*.json"))
        assert fixtures, "contracts/fixtures/ is the round-trip corpus — it must not be empty"
        r = subprocess.run(  # noqa: S603 — fixed argv from constants
            [_PYTHON, str(_PROJECT_ROOT / "contracts" / "validate-contracts.py")],
            capture_output=True,
            text=True,
            timeout=60,
        )
        for fixture in fixtures:
            assert f"PASS: {fixture.name} round-trips" in r.stdout, r.stdout
        assert "PASS: schema and SchemaVersion.current agree" in r.stdout, r.stdout


class TestValidatorPrimitives:
    """Unit-level coverage of the validator's own keyword implementations.

    The failure-branch tests below drive `main()` end to end; these pin the
    individual keywords, including the ones the real schema happens not to
    exercise in a failing direction, so a regression in `validate()` cannot hide
    behind a fixture that never triggers it.
    """

    def test_type_keyword_accepts_and_rejects_each_json_type(self) -> None:
        mod = _load_validator()
        for kind, good, bad in [
            ("string", "s", 1),
            ("number", 1.5, "1.5"),
            ("integer", 3, 3.5),
            ("boolean", True, "true"),
            ("object", {}, []),
            ("array", [], {}),
            ("null", None, 0),
        ]:
            assert mod.validate(good, {"type": kind}, {}) == [], kind
            assert mod.validate(bad, {"type": kind}, {}), f"{kind} accepted {bad!r}"

    def test_booleans_are_not_numbers(self) -> None:
        """Python's bool-is-an-int would silently let `true` satisfy `number`."""
        mod = _load_validator()
        assert mod.validate(True, {"type": "number"}, {})
        assert mod.validate(False, {"type": "integer"}, {})

    def test_union_type_accepts_any_member(self) -> None:
        mod = _load_validator()
        schema = {"type": ["string", "number", "boolean"]}
        for value in ("s", 1, 1.5, True):
            assert mod.validate(value, schema, {}) == [], value
        assert mod.validate(None, schema, {})

    def test_unknown_type_name_is_a_schema_error_not_a_pass(self) -> None:
        mod = _load_validator()
        with pytest.raises(mod.SchemaError, match="unknown type"):
            mod.validate("x", {"type": "text"}, {})

    def test_const_enum_minlength_pattern_and_minimum(self) -> None:
        mod = _load_validator()
        assert mod.validate("1.0", {"const": "1.0"}, {}) == []
        assert mod.validate("2.0", {"const": "1.0"}, {})
        assert mod.validate("PASS", {"enum": ["PASS", "FAIL"]}, {}) == []
        assert mod.validate("MAYBE", {"enum": ["PASS", "FAIL"]}, {})
        assert mod.validate("", {"minLength": 1}, {})
        assert mod.validate("2026-08-04T09:20:31Z", {"pattern": r"^\d{4}-"}, {}) == []
        assert mod.validate("today", {"pattern": r"^\d{4}-"}, {})
        assert mod.validate(-0.1, {"minimum": 0}, {})
        assert mod.validate(0, {"minimum": 0}, {}) == []

    def test_required_and_additional_properties(self) -> None:
        mod = _load_validator()
        schema = {
            "type": "object",
            "required": ["a"],
            "properties": {"a": {"type": "string"}},
            "additionalProperties": False,
        }
        assert mod.validate({"a": "x"}, schema, {}) == []
        assert "missing required property 'a'" in mod.validate({}, schema, {})[0]
        assert "unexpected property 'b'" in mod.validate({"a": "x", "b": 1}, schema, {})[0]

    def test_additional_properties_as_a_schema_is_applied(self) -> None:
        """How `attributes` is typed: any key, but the value must be a primitive."""
        mod = _load_validator()
        schema = {"type": "object", "additionalProperties": {"type": ["string", "number"]}}
        assert mod.validate({"anything": "x", "n": 2}, schema, {}) == []
        assert mod.validate({"bad": {}}, schema, {})

    def test_min_items_and_per_item_validation(self) -> None:
        mod = _load_validator()
        schema = {"type": "array", "minItems": 1, "items": {"type": "string"}}
        assert mod.validate(["a"], schema, {}) == []
        assert "at least 1 item" in mod.validate([], schema, {})[0]
        assert "[1]" in mod.validate(["a", 2], schema, {})[0]

    def test_every_violation_is_reported_not_just_the_first(self) -> None:
        mod = _load_validator()
        schema = {
            "type": "object",
            "required": ["a", "b"],
            "properties": {"c": {"type": "string"}},
        }
        errors = mod.validate({"c": 1}, schema, {})
        assert len(errors) == 3, errors

    def test_resolve_follows_local_refs(self) -> None:
        mod = _load_validator()
        root = {"$defs": {"rect": {"type": "object"}}}
        assert mod.resolve({"$ref": "#/$defs/rect"}, root) == {"type": "object"}
        assert mod.validate([], {"$ref": "#/$defs/rect"}, root)

    def test_unsupported_keywords_walks_nested_schemas(self) -> None:
        mod = _load_validator()
        assert mod.unsupported_keywords({"type": "object", "description": "fine"}) == []
        found = mod.unsupported_keywords(
            {
                "properties": {"a": {"oneOf": []}},
                "$defs": {"b": {"items": {"uniqueItems": True}}},
                "additionalProperties": {"maxProperties": 2},
            }
        )
        assert sorted(found) == [
            "#/$defs/b/items/uniqueItems",
            "#/additionalProperties/maxProperties",
            "#/properties/a/oneOf",
        ], found

    def test_the_real_schema_uses_only_implemented_keywords(self) -> None:
        """Guards the reverse direction: the gate must not have drifted behind the schema."""
        mod = _load_validator()
        schema = json.loads((_PROJECT_ROOT / "contracts" / "verdict-schema.json").read_text())
        assert mod.unsupported_keywords(schema) == []


class TestValidateContractsFailureBranches:
    """Each failure the validator promises to catch, proven by making it happen.

    A gate is only worth its PASS if its FAIL is reachable. Every case here builds
    a broken contracts/ directory in a tmp_path and asserts both the non-zero exit
    and the message that names the defect — otherwise a validator could return 1
    for an unrelated reason and look correct.
    """

    @staticmethod
    def _stage(tmp_path: Path) -> tuple[Path, Path]:
        """A copy of the real contracts/ plus a copy of SchemaVersion.swift."""
        source = _PROJECT_ROOT / "contracts"
        contracts = tmp_path / "contracts"
        (contracts / "fixtures").mkdir(parents=True)
        (contracts / "verdict-schema.json").write_text((source / "verdict-schema.json").read_text())
        for fixture in (source / "fixtures").glob("*.json"):
            (contracts / "fixtures" / fixture.name).write_text(fixture.read_text())
        kernel = tmp_path / "SchemaVersion.swift"
        kernel.write_text(
            (_PROJECT_ROOT / "Sources" / "VerdictUIKernel" / "SchemaVersion.swift").read_text()
        )
        return contracts, kernel

    def _run(self, contracts: Path, kernel: Path) -> tuple[int, str]:
        mod = _load_validator()
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = mod.main(["--contracts", str(contracts), "--kernel-source", str(kernel)])
        return code, buffer.getvalue()

    def test_staged_copy_passes_before_any_tampering(self, tmp_path: Path) -> None:
        """Control: without this, a later FAIL might just mean the copy was broken."""
        contracts, kernel = self._stage(tmp_path)
        code, output = self._run(contracts, kernel)
        assert code == 0, output

    def test_unparseable_schema_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        (contracts / "verdict-schema.json").write_text('{"type": "object",}')
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "unreadable" in output, output

    def test_schema_that_is_not_an_object_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        (contracts / "verdict-schema.json").write_text("[]")
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "not a schema object" in output, output

    def test_missing_schema_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        (contracts / "verdict-schema.json").unlink()
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "not found" in output, output

    def test_version_drift_between_schema_and_kernel_fails(self, tmp_path: Path) -> None:
        """The behaviour SchemaVersion.swift's doc comment promises."""
        contracts, kernel = self._stage(tmp_path)
        kernel_source = kernel.read_text()
        kernel.write_text(
            re.sub(
                r'(static\s+let\s+current\s*=\s*)"[^"]+"',
                r'\g<1>"2.0"',
                kernel_source,
                count=1,
            )
        )
        assert 'current = "2.0"' in kernel.read_text(), "drift was not actually introduced"
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "version drift" in output, output
        assert "'2.0'" in output, output

    def test_stale_id_url_fails_even_when_const_agrees(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        schema = json.loads((contracts / "verdict-schema.json").read_text())
        schema["$id"] = "https://verdictui.dev/schemas/verdict/0.9.json"
        (contracts / "verdict-schema.json").write_text(json.dumps(schema))
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "$id" in output, output

    def test_kernel_source_without_a_version_declaration_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        kernel.write_text("public enum SchemaVersion {}\n")
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "no 'static let current'" in output, output

    def test_fixture_violating_the_schema_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        target = contracts / "fixtures" / "verdict-pass.json"
        payload = json.loads(target.read_text())
        del payload["timing"]  # required by the schema
        payload["status"] = "MAYBE"  # outside the enum
        payload["findings"] = "none"  # wrong type
        payload["surprise"] = 1  # additionalProperties: false
        target.write_text(json.dumps(payload))
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "violates the schema" in output, output
        for expected in (
            "missing required property 'timing'",
            "'MAYBE' is not one of",
            "expected type array",
            "unexpected property 'surprise'",
        ):
            assert expected in output, f"{expected!r} not reported:\n{output}"

    def test_fixture_violating_a_nested_ref_fails(self, tmp_path: Path) -> None:
        """Proves $ref resolution is real: the defect is three levels deep."""
        contracts, kernel = self._stage(tmp_path)
        target = contracts / "fixtures" / "verdict-fail.json"
        payload = json.loads(target.read_text())
        payload["tree"]["children"][0]["role"] = ""  # minLength: 1 via $defs/semanticNode
        payload["delta"]["removed"][0] = []  # minItems: 1 via $defs/nodePath
        target.write_text(json.dumps(payload))
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "shorter than minLength 1" in output, output
        assert "expected at least 1 item" in output, output

    def test_unreadable_fixture_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        (contracts / "fixtures" / "broken.json").write_text("{not json")
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "broken.json unreadable" in output, output

    def test_empty_fixture_directory_fails(self, tmp_path: Path) -> None:
        """A round-trip check over zero fixtures proves nothing, so it must not pass."""
        contracts, kernel = self._stage(tmp_path)
        for fixture in (contracts / "fixtures").glob("*.json"):
            fixture.unlink()
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "nothing round-tripped" in output, output

    def test_absent_fixture_directory_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        shutil.rmtree(contracts / "fixtures")
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "nothing round-tripped" in output, output

    def test_schema_keyword_the_validator_cannot_enforce_fails(self, tmp_path: Path) -> None:
        """The anti-soft-pass guard: an unimplemented keyword must never be ignored."""
        contracts, kernel = self._stage(tmp_path)
        schema = json.loads((contracts / "verdict-schema.json").read_text())
        schema["$defs"]["finding"]["properties"]["message"]["maxLength"] = 200
        (contracts / "verdict-schema.json").write_text(json.dumps(schema))
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "does not implement" in output, output
        assert "maxLength" in output, output

    def test_unresolvable_ref_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        schema = json.loads((contracts / "verdict-schema.json").read_text())
        schema["properties"]["timing"] = {"$ref": "#/$defs/nowhere"}
        (contracts / "verdict-schema.json").write_text(json.dumps(schema))
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "does not resolve" in output, output

    def test_remote_ref_fails_rather_than_being_skipped(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        schema = json.loads((contracts / "verdict-schema.json").read_text())
        schema["properties"]["timing"] = {"$ref": "https://example.com/timing.json"}
        (contracts / "verdict-schema.json").write_text(json.dumps(schema))
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "unsupported $ref" in output, output


class TestRunbookCommandsNameRealVerbs:
    """A runbook command that cannot run is worse than a missing one.

    `floor-check.py` asserts `docs/runbook.md` EXISTS. Presence is not value
    (lesson 346): on 2026-08-11 the runbook carried a literal
    `printf … | nc -U ~/.verdictui/daemon.sock` example against a socket
    nothing in the package ever creates, because `VerdictDaemon` shipped its
    method surface with no transport. A cold-read audit found it; no automated
    check could, and the reader most likely to hit it is the one who cannot
    check (`no.md` #34).

    This closes the narrow, checkable half: every `verdictui <verb>` the
    runbook invokes must be a subcommand the CLI actually declares. It cannot
    judge prose — deciding whether an arbitrary paragraph describes shipped
    code is a judgement, not a pattern — so the runbook's own NOT RUNNABLE YET
    marker carries the rest, and this test guards the part a machine can see.
    """

    @staticmethod
    def _declared_subcommands() -> set[str]:
        source = (
            _PROJECT_ROOT / "Sources" / "VerdictUICLICore" / "CommandLineInterface.swift"
        ).read_text(encoding="utf-8")
        return set(re.findall(r'commandName:\s*"([a-z][a-z-]*)"', source))

    @staticmethod
    def _runbook_invocations() -> set[str]:
        text = (_PROJECT_ROOT / "docs" / "runbook.md").read_text(encoding="utf-8")
        verbs: set[str] = set()
        for line in text.splitlines():
            stripped = line.strip()
            # Only lines that INVOKE the tool, not prose that names it. A
            # backticked mention inside a sentence is documentation about a
            # verb, not a command a reader will paste.
            for match in re.finditer(r"(?:^|[`\s./])verdictui\s+([a-z][a-z-]*)", stripped):
                verbs.add(match.group(1))
        return verbs

    def test_every_runbook_verb_is_a_real_subcommand(self) -> None:
        declared = self._declared_subcommands()
        assert declared, "no subcommands parsed — the extractor is broken, not the runbook"

        invoked = self._runbook_invocations()
        unknown = invoked - declared - {"daemon", "mcp"}  # see the exemption test
        assert not unknown, (
            f"docs/runbook.md invokes `verdictui {sorted(unknown)}`, which the CLI does not "
            f"declare. Declared: {sorted(declared)}. A runbook command that cannot run is "
            "worse than a missing one (no.md #34)."
        )

    def test_a_verb_the_cli_lacks_must_be_marked_not_runnable(self) -> None:
        """The control, and the reason the exemption above is not a hole.

        `daemon` and `mcp` are exempted from the check above because the
        runbook DISCUSSES them — their transports are CTS-81D9483D. That
        exemption is only honest while the runbook says so out loud, so this
        asserts the marker is present. Delete the marker and this fails.
        """
        text = (_PROJECT_ROOT / "docs" / "runbook.md").read_text(encoding="utf-8")
        declared = self._declared_subcommands()

        for verb in ("daemon", "mcp"):
            if verb in declared:
                continue  # the transport landed; nothing to mark
            assert "NOT RUNNABLE YET" in text, (
                f"the runbook describes `{verb}` but the CLI does not declare it, and the "
                "NOT RUNNABLE YET marker is gone — a reader would take the description for a "
                "working feature (no.md #34)"
            )

    def test_the_runbook_gives_no_command_for_an_absent_transport(self) -> None:
        """No pasteable example may exist for a verb that cannot run.

        The specific defect: a `nc -U ~/.verdictui/daemon.sock` line against a
        socket nothing creates. The marker alone is not enough — a reader who
        skims to the code block never sees it.
        """
        text = (_PROJECT_ROOT / "docs" / "runbook.md").read_text(encoding="utf-8")
        if "daemon" in self._declared_subcommands():
            return  # the transport exists; an example is now correct

        assert "nc -U" not in text, (
            "docs/runbook.md gives an `nc -U` example for a socket no code in this package "
            "binds. Remove the example until the transport ships (CTS-81D9483D)."
        )

    def test_the_mcp_registration_names_a_verb_the_cli_declares(self) -> None:
        """`.mcp.json` is a pasteable command with no reader to notice it broke.

        It is the same class as the runbook examples above, one step worse: a
        runbook line is read by a human who can react to an error, while this is
        launched by an editor that reports only that the server failed to start.
        The args must therefore name a real subcommand.
        """
        config = _PROJECT_ROOT / ".mcp.json"
        if not config.exists():
            pytest.skip("no project-scoped MCP registration")

        entry = json.loads(config.read_text(encoding="utf-8"))["mcpServers"]["verdictui"]
        verb = entry["args"][0]
        declared = self._declared_subcommands()

        assert declared, "no subcommands parsed — the extractor is broken, not the config"
        assert verb in declared, (
            f".mcp.json launches `verdictui {verb}`, which the CLI does not declare. "
            f"Declared: {sorted(declared)}. The editor would report only that the server "
            "failed to start."
        )

    def test_the_mcp_registration_points_at_a_binary_that_exists(self) -> None:
        """The registered PATH must exist and be executable.

        It lives under `.build/`, which is gitignored and which
        `swift package clean` removes — so this config goes stale with no edit
        to it and no signal anywhere. A path is a claim about the filesystem,
        and the only way to check a claim about the filesystem is to look.

        Skipped on a clean checkout, where nothing has been built yet: that is
        "could not observe", not "observed and broken" (lesson 206).
        """
        config = _PROJECT_ROOT / ".mcp.json"
        if not config.exists():
            pytest.skip("no project-scoped MCP registration")

        entry = json.loads(config.read_text(encoding="utf-8"))["mcpServers"]["verdictui"]
        binary = Path(entry["command"])

        if not binary.parent.exists():
            pytest.skip(f"{binary.parent} absent — nothing built in this checkout yet")

        assert binary.exists(), (
            f".mcp.json points at {binary}, which does not exist. Rebuild with "
            "`swift build -c release --product verdictui`, or repoint the config."
        )
        assert binary.stat().st_mode & 0o111, f"{binary} is not executable"
