"""Tests for scripts/kernel-symbol-audit.py.

The audit script is what the Wave 1 exit gate leans on for "every public kernel
symbol has a doc comment and at least one test exercising it". An audit that
under-reports is worse than none — it turns an unproven gate into a green one —
so each classification rule is pinned here against a synthetic kernel whose
expected verdict is written out by hand.
"""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
from typing import Any

import pytest

pytestmark = pytest.mark.quick

_PROJECT_ROOT = Path(__file__).resolve().parents[1]


def _load_audit() -> Any:
    """Import the hyphen-named script as a module. `Any`, because the tests rebind
    its path constants — a `ModuleType` annotation would reject that."""
    path = str(_PROJECT_ROOT / "scripts" / "kernel-symbol-audit.py")
    spec = importlib.util.spec_from_file_location("verdictui_kernel_symbol_audit", path)
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _stage(tmp_path: Path, source: str, tests: str = "") -> Any:
    """A synthetic kernel + kernel-test tree the audit can be pointed at."""
    mod = _load_audit()
    kernel = tmp_path / "Sources" / "VerdictUIKernel"
    kernel_tests = tmp_path / "Tests" / "VerdictUIKernelTests"
    kernel.mkdir(parents=True)
    kernel_tests.mkdir(parents=True)
    (kernel / "Subject.swift").write_text(source)
    (kernel_tests / "SubjectTests.swift").write_text(tests)
    mod.PROJECT_ROOT = tmp_path
    mod.KERNEL_DIR = kernel
    mod.KERNEL_TEST_DIR = kernel_tests
    return mod


class TestSymbolCollection:
    def test_public_types_members_and_cases_are_collected(self, tmp_path: Path) -> None:
        mod = _stage(
            tmp_path,
            """
/// A type.
public struct Widget {
    /// A computed property.
    public var label: String { "x" }
    /// A method.
    public func draw() {}
    public var stored: Int
    public init(stored: Int) { self.stored = stored }
}

/// An enum.
public enum Mode {
    /// One way.
    case fast
    /// Another.
    case slow
}
""",
        )
        found = {(s.owner, s.name, s.kind) for s in mod.collect_symbols()}
        assert ("", "Widget", "struct") in found
        assert ("Widget", "label", "var") in found
        assert ("Widget", "draw", "func") in found
        assert ("Widget", "stored", "var") in found
        assert ("Widget", "init", "init") in found
        assert ("Mode", "fast", "case") in found
        assert ("Mode", "slow", "case") in found

    def test_non_public_declarations_are_ignored(self, tmp_path: Path) -> None:
        mod = _stage(
            tmp_path,
            """
struct Internal {
    var hidden: Int = 0
    func work() {}
}

/// Public.
public struct Exposed {
    private var secret: Int = 0
    func packagePrivate() {}
}
""",
        )
        names = {s.name for s in mod.collect_symbols()}
        assert names == {"Exposed"}, names

    def test_switch_cases_are_not_mistaken_for_enum_cases(self, tmp_path: Path) -> None:
        """A `switch` body is full of `case` lines that declare nothing."""
        mod = _stage(
            tmp_path,
            """
/// An enum.
public enum Mode {
    /// Fast.
    case fast
    /// Label.
    public var label: String {
        switch self {
        case .fast: "fast"
        }
    }
}
""",
        )
        cases = [s.name for s in mod.collect_symbols() if s.kind == "case"]
        assert cases == ["fast"], cases

    def test_public_members_inside_an_extension_are_collected(self, tmp_path: Path) -> None:
        """An extension has no access level of its own — its members still count."""
        mod = _stage(
            tmp_path,
            """
extension Widget {
    /// Extended.
    public func extra() {}
}
""",
        )
        found = {(s.owner, s.name) for s in mod.collect_symbols()}
        assert ("Widget", "extra") in found

    def test_comma_separated_cases_on_one_line_are_all_collected(self, tmp_path: Path) -> None:
        mod = _stage(
            tmp_path,
            """
/// An enum.
public enum Mode {
    /// Both.
    case fast, slow
}
""",
        )
        assert {s.name for s in mod.collect_symbols() if s.kind == "case"} == {"fast", "slow"}


class TestDocPolicy:
    def test_undocumented_public_symbol_is_a_doc_gap(self, tmp_path: Path) -> None:
        mod = _stage(tmp_path, "public struct Widget {}\n", "Widget()\n")
        result = mod.audit()
        assert [s.display for s in result.doc_gaps] == ["Widget"]

    def test_doc_comment_is_seen_through_an_attribute_line(self, tmp_path: Path) -> None:
        mod = _stage(
            tmp_path,
            """
/// Documented, with an attribute in between.
@frozen
public struct Widget {}
""",
            "Widget()\n",
        )
        assert mod.audit().doc_gaps == []

    def test_initializers_and_stored_properties_are_doc_exempt(self, tmp_path: Path) -> None:
        mod = _stage(
            tmp_path,
            """
/// A type.
public struct Widget {
    public var width: Double
    public init(width: Double) { self.width = width }
}
""",
            "Widget(width: 1).width\n",
        )
        result = mod.audit()
        assert result.doc_gaps == [], [s.display for s in result.doc_gaps]

    def test_static_constants_still_require_a_doc(self, tmp_path: Path) -> None:
        """`static let id = "tap-target"` is API a caller reads — not a field of state."""
        mod = _stage(
            tmp_path,
            """
/// A rule.
public struct Rule {
    public static let id = "rule"
}
""",
            "Rule.id\n",
        )
        assert [s.display for s in mod.audit().doc_gaps] == ["Rule.id"]

    def test_documented_protocol_requirement_covers_its_implementations(
        self, tmp_path: Path
    ) -> None:
        mod = _stage(
            tmp_path,
            """
/// A protocol.
public protocol LintRule {
    /// Stable identifier.
    static var id: String { get }
}

/// A rule.
public struct Rule: LintRule {
    public static var id: String { "rule" }
}
""",
            "LintRule.self\nRule.id\n",
        )
        result = mod.audit()
        assert result.doc_gaps == [], [s.display for s in result.doc_gaps]
        assert result.inherited_docs == 1

    def test_inheritance_does_not_excuse_an_undocumented_requirement(self, tmp_path: Path) -> None:
        """If the protocol requirement itself lacks a doc, nothing is inherited."""
        mod = _stage(
            tmp_path,
            """
/// A protocol.
public protocol LintRule {
    static var id: String { get }
}

/// A rule.
public struct Rule: LintRule {
    public static var id: String { "rule" }
}
""",
            "LintRule.self\nRule.id\n",
        )
        result = mod.audit()
        assert sorted(s.display for s in result.doc_gaps) == ["LintRule.id", "Rule.id"]
        assert result.inherited_docs == 0

    def test_inheritance_only_applies_to_declared_conformances(self, tmp_path: Path) -> None:
        mod = _stage(
            tmp_path,
            """
/// A protocol.
public protocol LintRule {
    /// Stable identifier.
    static var id: String { get }
}

/// Unrelated.
public struct Other {
    public static var id: String { "other" }
}
""",
            "LintRule.self\nOther.id\n",
        )
        assert [s.display for s in mod.audit().doc_gaps] == ["Other.id"]


class TestTestPolicy:
    def test_symbol_no_test_mentions_is_a_test_gap(self, tmp_path: Path) -> None:
        mod = _stage(tmp_path, "/// A type.\npublic struct Widget {}\n", "// nothing here\n")
        assert [s.display for s in mod.audit().test_gaps] == ["Widget"]

    def test_mention_anywhere_in_the_kernel_tests_satisfies_the_floor(self, tmp_path: Path) -> None:
        mod = _stage(tmp_path, "/// A type.\npublic struct Widget {}\n", "let w = Widget()\n")
        assert mod.audit().test_gaps == []

    def test_partial_word_matches_do_not_count(self, tmp_path: Path) -> None:
        """`WidgetFactory` must not satisfy `Widget` — identifiers match whole-word."""
        mod = _stage(tmp_path, "/// A type.\npublic struct Widget {}\n", "WidgetFactory()\n")
        assert [s.display for s in mod.audit().test_gaps] == ["Widget"]

    def test_an_initializer_is_satisfied_by_mentioning_its_type(self, tmp_path: Path) -> None:
        """`init` is not a searchable identifier, so the owner name stands in."""
        mod = _stage(
            tmp_path,
            "/// A type.\npublic struct Widget {\n    public init() {}\n}\n",
            "Widget()\n",
        )
        assert mod.audit().test_gaps == []


class TestReportingAndExitCodes:
    def test_clean_kernel_exits_zero_and_says_pass(self, tmp_path: Path) -> None:
        mod = _stage(tmp_path, "/// A type.\npublic struct Widget {}\n", "Widget()\n")
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = mod.main()
        assert code == 0
        assert "PASS" in buffer.getvalue()

    def test_gaps_exit_one_and_name_the_symbol(self, tmp_path: Path) -> None:
        mod = _stage(tmp_path, "public struct Widget {}\n", "")
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = mod.main()
        output = buffer.getvalue()
        assert code == 1
        assert "FAIL: 2 gap(s)" in output, output
        assert "undocumented" in output and "untested" in output

    def test_json_output_is_machine_readable(self, tmp_path: Path) -> None:
        mod = _stage(tmp_path, "public struct Widget {}\n", "")
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = mod.main(["--json"])
        payload = json.loads(buffer.getvalue())
        assert code == 1
        assert payload["total_gaps"] == 2
        assert payload["audited"] == 1
        assert payload["doc_gaps"][0]["symbol"] == "Widget"
        assert payload["doc_gaps"][0]["file"] == "Sources/VerdictUIKernel/Subject.swift"

    def test_missing_kernel_directory_fails_loudly(self, tmp_path: Path) -> None:
        mod = _stage(tmp_path, "public struct Widget {}\n", "")
        mod.KERNEL_DIR = tmp_path / "absent"
        with pytest.raises(SystemExit, match="kernel directory missing"):
            mod.audit()

    def test_missing_test_directory_fails_loudly(self, tmp_path: Path) -> None:
        mod = _stage(tmp_path, "public struct Widget {}\n", "")
        mod.KERNEL_TEST_DIR = tmp_path / "absent"
        with pytest.raises(SystemExit, match="kernel test directory missing"):
            mod.audit()

    def test_total_gaps_sums_both_categories(self, tmp_path: Path) -> None:
        mod = _load_audit()
        result = mod.AuditResult()
        assert result.total_gaps == 0
        result.doc_gaps.append(object())
        result.test_gaps.extend([object(), object()])
        assert result.total_gaps == 3

    def test_display_qualifies_a_member_with_its_owner(self) -> None:
        mod = _load_audit()
        member = mod.Symbol(
            name="id",
            kind="let",
            owner="Rule",
            file="f.swift",
            line=1,
            documented=True,
            doc_required=True,
        )
        top_level = mod.Symbol(
            name="Rule",
            kind="struct",
            owner="",
            file="f.swift",
            line=1,
            documented=True,
            doc_required=True,
        )
        assert member.display == "Rule.id"
        assert top_level.display == "Rule"

    def test_scope_records_conformances(self) -> None:
        mod = _load_audit()
        scope = mod.Scope(indent=0, kind="struct", name="Rule", is_public=True)
        assert scope.conformances == ()


class TestRealKernel:
    def test_the_shipped_kernel_has_no_doc_or_test_gaps(self) -> None:
        """The exit-gate assertion itself, run against the real sources."""
        mod = _load_audit()
        result = mod.audit()
        assert result.symbols, "audit found no symbols — the scan is broken, not the kernel clean"
        assert not result.doc_gaps, [s.display for s in result.doc_gaps]
        assert not result.test_gaps, [s.display for s in result.test_gaps]
