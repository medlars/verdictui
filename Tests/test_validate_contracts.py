"""Tests for contracts/validate-contracts.py -- the verdict wire contract gate.

The validator is deliberately hand-rolled (ADR 2026-003: no runtime Python
dependencies), so these tests pin every check it makes and every fail-closed
path -- an unimplemented keyword, an unreadable fixture, version drift -- must
FAIL, never silently pass.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

_VC_PATH = Path(__file__).resolve().parents[1] / "contracts" / "validate-contracts.py"
_spec = importlib.util.spec_from_file_location("validate_contracts", _VC_PATH)
assert _spec is not None and _spec.loader is not None, "validate-contracts.py not found"
_vc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_vc)

# The file is hyphen-named so it cannot be imported as a module; bind the
# names the tests exercise so both ruff and pyright see real definitions.
SchemaError = _vc.SchemaError
_check_array = _vc._check_array
_check_fixtures = _vc._check_fixtures
_check_object = _vc._check_object
_check_scalars = _vc._check_scalars
_check_type = _vc._check_type
_check_version_agreement = _vc._check_version_agreement
_declared_version = _vc._declared_version
_kernel_version = _vc._kernel_version
_load_schema = _vc._load_schema
main = _vc.main
resolve = _vc.resolve
unsupported_keywords = _vc.unsupported_keywords
validate = _vc.validate

_PROJECT = Path(__file__).resolve().parents[1]
_KERNEL_SOURCE = _PROJECT / "Sources" / "VerdictUIKernel" / "SchemaVersion.swift"

# SENTINEL-FOR-APPEND


class TestSchemaIntegrity:
    def test_resolve_follows_a_def_ref(self) -> None:
        target = {"type": "string"}
        root = {"$defs": {"Name": target}}
        assert resolve({"$ref": "#/$defs/Name"}, root) is target

    def test_resolve_rejects_an_unsupported_pointer(self) -> None:
        with pytest.raises(SchemaError):
            resolve({"$ref": "#/definitions/Name"}, {"$defs": {}})

    def test_resolve_rejects_a_missing_def(self) -> None:
        with pytest.raises(SchemaError):
            resolve({"$ref": "#/$defs/Absent"}, {"$defs": {}})

    def test_annotation_keywords_are_ignored_not_enforced(self) -> None:
        assert unsupported_keywords({"title": "x", "$id": "y", "description": "z"}) == []

    def test_an_unimplemented_keyword_is_reported(self) -> None:
        assert unsupported_keywords({"type": "string", "maxItems": 3}) == ["#/maxItems"]

    def test_nested_keywords_are_walked(self) -> None:
        found = unsupported_keywords({"properties": {"a": {"items": {"uniqueItems": True}}}})
        assert found == ["#/properties/a/items/uniqueItems"]


class TestInstanceValidation:
    def test_a_type_mismatch_is_collected(self) -> None:
        errors: list[str] = []
        _check_type("x", "number", "$", errors)
        assert "expected type number" in errors[0]

    def test_an_unknown_type_raises_instead_of_validating_nothing(self) -> None:
        errors: list[str] = []
        with pytest.raises(SchemaError):
            _check_type("x", "int32", "$", errors)

    def test_bool_is_not_an_integer(self) -> None:
        errors: list[str] = []
        _check_type(True, "integer", "$", errors)
        assert errors, "bool must not satisfy the integer predicate"

    def test_union_types_admit_each_member(self) -> None:
        errors: list[str] = []
        _check_type(1.5, ["integer", "number"], "$", errors)
        assert errors == []

    def test_a_missing_required_property_is_collected(self) -> None:
        errors: list[str] = []
        _check_object({"a": 1}, {"required": ["a", "b"]}, {}, "$", errors)
        assert "missing required property 'b'" in errors[0]

    def test_additional_properties_false_flags_extras(self) -> None:
        errors: list[str] = []
        schema = {"properties": {"known": {}}, "additionalProperties": False}
        _check_object({"known": 1, "extra": 2}, schema, {}, "$", errors)
        assert "unexpected property 'extra'" in errors[0]

    def test_additional_properties_schema_validates_the_member(self) -> None:
        errors: list[str] = []
        schema = {"properties": {"known": {}}, "additionalProperties": {"type": "string"}}
        _check_object({"known": 1, "extra": 7}, schema, {}, "$", errors)
        assert "$/extra: expected type string" in errors[0]


class TestArrayAndScalarChecks:
    def test_min_items_is_enforced(self) -> None:
        errors: list[str] = []
        _check_array([1], {"minItems": 2, "items": {}}, {}, "$", errors)
        assert "expected at least 2 item(s)" in errors[0]

    def test_items_are_validated_with_indexed_paths(self) -> None:
        errors: list[str] = []
        _check_array(["ok", 7], {"items": {"type": "string"}}, {}, "$", errors)
        assert "$[1]: expected type string" in errors[0]

    def test_min_length_pattern_and_minimum_are_enforced(self) -> None:
        errors: list[str] = []
        _check_scalars("ab", {"minLength": 3, "pattern": "^a+$"}, "$", errors)
        assert any("shorter than minLength" in e for e in errors)
        assert any("does not match" in e for e in errors)

    def test_bool_does_not_reach_the_minimum_check(self) -> None:
        errors: list[str] = []
        _check_scalars(True, {"minimum": 5}, "$", errors)
        assert errors == [], "bool is excluded from the minimum check"

    def test_a_number_below_minimum_is_collected(self) -> None:
        errors: list[str] = []
        _check_scalars(1, {"minimum": 5}, "$", errors)
        assert "below minimum" in errors[0]


class TestValidateTopLevel:
    def test_const_and_enum_violations_are_collected(self) -> None:
        errors = validate(2, {"const": 1}, {"const": 1})
        assert "expected const 1" in errors[0]
        errors = validate("x", {"enum": ["a", "b"]}, {"enum": ["a", "b"]})
        assert "is not one of" in errors[0]

    def test_a_ref_is_followed_before_type_checking(self) -> None:
        root = {"$defs": {"Name": {"type": "string"}}}
        assert validate(7, {"$ref": "#/$defs/Name"}, root) != []

    def test_errors_accumulate_rather_than_short_circuiting(self) -> None:
        schema = {
            "type": "object",
            "required": ["a", "b"],
            "properties": {"a": {"type": "string"}},
        }
        errors = validate({"a": 5, "c": 7}, schema, schema)
        # Extra properties are LEGAL without additionalProperties:false -- the
        # engine correctly reports only the missing 'b' and the wrong-type 'a'.
        assert len(errors) == 2
        assert any("missing required property 'b'" in e for e in errors)

    def test_every_violation_is_reported_when_extras_are_forbidden(self) -> None:
        schema = {
            "type": "object",
            "required": ["a", "b"],
            "properties": {"a": {"type": "string"}},
            "additionalProperties": False,
        }
        errors = validate({"a": 5, "c": 7}, schema, schema)
        assert len(errors) == 3, "missing b, wrong-type a, AND unexpected c all reported"


class TestVersionAgreement:
    def test_a_valid_schema_declares_a_string_version(self) -> None:
        schema = {"properties": {"schemaVersion": {"const": "1.1"}}, "$id": "https://x/1.1"}
        assert _declared_version(schema) == "1.1"

    def test_a_schema_without_the_version_const_raises(self) -> None:
        with pytest.raises(SchemaError):
            _declared_version({})

    def test_a_non_string_version_raises(self) -> None:
        with pytest.raises(SchemaError):
            _declared_version({"properties": {"schemaVersion": {"const": 1.1}}})

    def test_the_kernel_version_is_read_from_the_swift_source(self, tmp_path: Path) -> None:
        source = tmp_path / "SchemaVersion.swift"
        source.write_text('public enum SchemaVersion {\n    public static let current = "1.1"\n}\n')
        assert _kernel_version(source) == "1.1"

    def test_a_source_without_the_declaration_raises(self, tmp_path: Path) -> None:
        source = tmp_path / "SchemaVersion.swift"
        source.write_text("public enum SchemaVersion {}\n")
        with pytest.raises(SchemaError):
            _kernel_version(source)

    def test_agreement_records_no_failure_on_the_real_kernel(self) -> None:
        failures: list[str] = []
        _check_version_agreement(
            {"properties": {"schemaVersion": {"const": "1.1"}}, "$id": "https://x/1.1"},
            _KERNEL_SOURCE,
            failures,
        )
        assert failures == []

    def test_drift_names_both_sides(self) -> None:
        schema = {"properties": {"schemaVersion": {"const": "9.9"}}, "$id": "https://x/9.9"}
        failures: list[str] = []
        _check_version_agreement(schema, _KERNEL_SOURCE, failures)
        assert len(failures) == 1
        assert "9.9" in failures[0] and "1.1" in failures[0]

    def test_an_id_missing_the_version_is_drift(self) -> None:
        schema = {"properties": {"schemaVersion": {"const": "1.1"}}, "$id": "https://x/v1"}
        failures: list[str] = []
        _check_version_agreement(schema, _KERNEL_SOURCE, failures)
        assert any("$id" in f for f in failures)


class TestFixturesCheck:
    def test_a_missing_fixture_directory_fails(self, tmp_path: Path) -> None:
        failures: list[str] = []
        _check_fixtures({}, tmp_path / "fixtures", failures)
        assert "no fixture directory" in failures[0]

    def test_an_empty_fixture_directory_fails(self, tmp_path: Path) -> None:
        failures: list[str] = []
        (tmp_path / "fixtures").mkdir()
        _check_fixtures({}, tmp_path / "fixtures", failures)
        assert "holds no fixtures" in failures[0]

    def test_a_valid_fixture_passes_and_an_invalid_one_fails(self, tmp_path: Path) -> None:
        fixture_dir = tmp_path / "fixtures"
        fixture_dir.mkdir()
        (fixture_dir / "good.json").write_text(json.dumps({"schemaVersion": "1.1"}))
        (fixture_dir / "bad.json").write_text(json.dumps({"schemaVersion": 7}))
        schema = {
            "type": "object",
            "properties": {"schemaVersion": {"const": "1.1"}},
            "additionalProperties": False,
        }
        failures: list[str] = []
        _check_fixtures(schema, fixture_dir, failures)
        assert not any("good.json" in f for f in failures)
        assert any("bad.json" in f for f in failures)


class TestLoadSchemaAndMain:
    def test_an_unreadable_schema_fails(self, tmp_path: Path) -> None:
        failures: list[str] = []
        assert _load_schema(tmp_path / "absent.json", failures) is None
        assert failures

    def test_a_non_dict_schema_fails(self, tmp_path: Path) -> None:
        schema_path = tmp_path / "schema.json"
        schema_path.write_text("[]")
        failures: list[str] = []
        assert _load_schema(schema_path, failures) is None
        assert "not a schema object" in failures[0]

    def test_an_unimplemented_keyword_fails_the_load(self, tmp_path: Path) -> None:
        schema_path = tmp_path / "schema.json"
        schema_path.write_text('{"type": "string", "maxItems": 3}')
        failures: list[str] = []
        assert _load_schema(schema_path, failures) is None
        assert "validator does not implement" in failures[0]

    def test_a_clean_schema_loads(self, tmp_path: Path) -> None:
        schema_path = tmp_path / "schema.json"
        schema_path.write_text('{"type": "string"}')
        failures: list[str] = []
        assert _load_schema(schema_path, failures) == {"type": "string"}
        assert failures == []

    def test_the_real_contract_passes_in_process(self) -> None:
        assert main(()) == 0

    def test_a_missing_schema_fails_closed(self, tmp_path: Path) -> None:
        assert main(["--contracts", str(tmp_path)]) == 1


# SENTINEL-FOR-APPEND
