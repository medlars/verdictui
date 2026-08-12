"""Keeps the macro target's cost off the products that do not ask for it.

Wave 4 adds `@Verifiable`, and macros cost build time: SwiftSyntax is by a wide
margin the heaviest thing in this package's dependency graph. The plan's Task 1
therefore makes macros an *optional* product rather than folding them into
`VerdictUIProbe` — a consumer that wants probes without paying for SwiftSyntax
must be able to say so, and today that is every consumer, since the probe
surface predates the macro.

That isolation is a structural claim about `Package.swift`, and structural
claims decay silently: adding one `.product(name: "SwiftSyntax", ...)` to the
wrong target's `dependencies` still compiles, still passes every Swift test, and
simply makes everyone's build slower forever. Nothing else in the suite can see
it, because the damage is not to behaviour.

Two directions are asserted, for the same reason `test_file_registry` asserts
two:

  * the shipping targets (`VerdictUIKernel`, `VerdictUIProbe`, and the demo
    surface that links them) must not reach SwiftSyntax, directly or through the
    macro-support library; and
  * the macro plugin itself must remain a `.macro` target, since demoting it to
    a plain `.target` would link the compiler plugin into the product graph —
    the precise failure this file exists to prevent.

The manifest is read as text rather than by invoking SwiftPM's own dependency
dump, deliberately: `swift package dump-package` reports what the manifest
*declares*, which is the same source this test reads, but costs a package
resolution on every run. The parsing is therefore kept blunt and total — a
manifest shape this parser does not recognise fails the test rather than
silently matching nothing (lesson 202: a check may only return clean for work it
actually performed).
"""

import re
from pathlib import Path

import pytest

pytestmark = pytest.mark.quick

_PROJECT_ROOT = Path(__file__).resolve().parents[1]
_MANIFEST = _PROJECT_ROOT / "Package.swift"

# The plugin target. Everything else in the package is shipping surface.
_MACRO_TARGET = "VerdictUIMacros"

# The library a consumer imports to GET the macro. It may depend on the plugin;
# nothing else may depend on either.
_MACRO_SUPPORT_TARGET = "VerdictUIMacroSupport"

# Targets that must stay free of SwiftSyntax. Named explicitly rather than
# derived as "everything else", so that a NEW target added without a decision
# fails this test instead of defaulting into whichever bucket is convenient.
#
# `VerdictUIMacroTests` is deliberately absent: it is the one test target that
# SHOULD reach SwiftSyntax, since asserting expansion text is its job.
_SWIFTSYNTAX_FREE_TARGETS = frozenset(
    {
        "VerdictUIKernel",
        "VerdictUIProbe",
        "VerdictUIDemoScenarios",
        "VerdictUIDemo",
        "VerdictUIKernelTests",
        "VerdictUIProbeTests",
        "VerdictUIDemoScenariosTests",
        # Wave 6's CLI. SwiftSyntax-free DELIBERATELY, and this is the
        # load-bearing half of the classification: `verdictui` is the binary a
        # user installs, so a dependency arrow from it to the macro plugin
        # would link the heaviest build-time cost in the package into a
        # shipping product. The CLI verifies scenarios that a macro may have
        # generated; it never expands one.
        "VerdictUICLICore",
        "VerdictUICLICoreTests",
        "verdictui",
        # Wave 8's cross-validation channel. SwiftSyntax-free for the same
        # reason the CLI is, and Accessibility-bearing besides: the witness
        # depends on the kernel alone, so neither ApplicationServices nor the
        # macro plugin reaches a consumer that only wants probes.
        "VerdictUIWitness",
        "VerdictUIWitnessTests",
        "verdictui-witness-host",
    }
)

# Every target the manifest may declare. The partition is asserted to be TOTAL
# (below) so that adding a target without classifying it fails here rather than
# escaping both buckets — the exact way a coverage list goes quietly incomplete
# (lesson 240: a gate iterating a hand-written list only checks what someone
# remembered to list).
_MACRO_SIDE_TARGETS = frozenset({_MACRO_TARGET, _MACRO_SUPPORT_TARGET, "VerdictUIMacroTests"})

_SWIFTSYNTAX_MARKERS = ("swift-syntax", "SwiftSyntax", "SwiftCompilerPlugin")


def _manifest_text() -> str:
    return _MANIFEST.read_text(encoding="utf-8")


def _strip_comments(text: str) -> str:
    """Remove `//` comments, preserving line structure.

    Comments are stripped before anything is judged because this manifest
    *explains* the SwiftSyntax isolation in prose sitting right next to the
    targets it protects. Matching that prose reports the documentation as the
    violation — which it did: the first run of this test named `VerdictUIProbe`
    and `VerdictUIDemoScenariosTests` as SwiftSyntax offenders when neither
    declares any dependency but `VerdictUIKernel`. A checker must judge what it
    parsed, not text that happens to fall inside the region it scanned
    (lesson 213).
    """
    return "\n".join(re.sub(r"//.*$", "", line) for line in text.splitlines())


def _target_blocks() -> dict[str, str]:
    """Map every declared target name to the DEPENDENCIES text of its declaration.

    Scoped to `dependencies:` rather than to the whole declaration for the same
    reason comments are stripped: a block that runs to the start of the next
    declaration also swallows the comment header introducing that next target,
    so `VerdictUIMacroTests`'s SwiftSyntax dependency was being attributed to
    whichever target happened to precede it. Judging the array itself is both
    narrower and exactly the claim being made — what a target DEPENDS on.
    """
    text = _strip_comments(_manifest_text())
    # `\.` then the kind: `executableTarget` and `testTarget` are matched before
    # bare `target` because the regex alternation is ordered and `target` is a
    # SUFFIX of both — `.testTarget(` would otherwise be split at `Target(`,
    # yielding a nameless fragment.
    decl = re.compile(r"\.(?:macro|executableTarget|testTarget|target)\s*\(", re.MULTILINE)
    starts = [m.start() for m in decl.finditer(text)]
    if not starts:
        pytest.fail(
            "Package.swift declares no targets that this parser recognises — the "
            "manifest shape changed and this test is no longer measuring anything."
        )

    blocks: dict[str, str] = {}
    for index, start in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(text)
        declaration = text[start:end]
        name_match = re.search(r'name:\s*"([^"]+)"', declaration)
        # `raise` rather than `pytest.fail(...)`: both fail the test, but only the
        # raise narrows `name_match` for mypy, which does not model pytest.fail as
        # NoReturn. (pyright does, and calls the line after a fail() unreachable —
        # so the two checkers this repo runs disagree on the fail() form.)
        if name_match is None:
            raise AssertionError(
                f"A target declaration in Package.swift has no name: {declaration[:120]!r}"
            )
        blocks[name_match.group(1)] = declaration
    return blocks


def _target_dependencies() -> dict[str, str]:
    """Map every declared target name to the text of its `dependencies:` array."""
    return {name: _dependencies_of(decl) for name, decl in _target_blocks().items()}


def _dependencies_of(declaration: str) -> str:
    """The text of a declaration's `dependencies:` array, or `""` if it has none.

    Bracket-matched rather than regex-terminated, because a dependency entry is
    itself bracketed (`.product(name:package:)`) and the first `]` a regex meets
    is usually not the array's. A target with no `dependencies:` returns the
    empty string, which is the honest answer — it depends on nothing — and keeps
    the caller from having to distinguish "absent" from "empty".
    """
    marker = re.search(r"dependencies:\s*\[", declaration)
    if marker is None:
        return ""
    start = marker.end() - 1
    depth = 0
    for offset in range(start, len(declaration)):
        character = declaration[offset]
        if character == "[":
            depth += 1
        elif character == "]":
            depth -= 1
            if depth == 0:
                return declaration[start : offset + 1]
    # An unbalanced array means the manifest does not parse as Swift at all, so
    # failing here beats silently judging a truncated dependency list.
    raise AssertionError(f"Unbalanced dependencies array in Package.swift: {declaration[:160]!r}")


class TestMacroTargetIsolation:
    def test_the_manifest_declares_the_macro_plugin_and_its_support_library(self) -> None:
        blocks = _target_blocks()
        missing = {_MACRO_TARGET, _MACRO_SUPPORT_TARGET} - blocks.keys()
        assert not missing, (
            f"Package.swift is missing {sorted(missing)}. Wave 4 Task 1 requires the "
            f"macro plugin and a separate support library so macros stay optional."
        )

    def test_every_declared_target_is_classified_by_this_file(self) -> None:
        """The two buckets must cover the manifest exactly.

        Without this, a target added later belongs to neither bucket and simply
        escapes the SwiftSyntax check — the check still passes, still reports
        clean, and covers one target less than the reader assumes.
        """
        declared = set(_target_blocks())
        classified = _SWIFTSYNTAX_FREE_TARGETS | _MACRO_SIDE_TARGETS
        unclassified = declared - classified
        assert not unclassified, (
            f"Package.swift declares targets this test does not classify: "
            f"{sorted(unclassified)}. Add each to _SWIFTSYNTAX_FREE_TARGETS (it must "
            f"not reach SwiftSyntax) or to _MACRO_SIDE_TARGETS (it may) — deciding is "
            f"the point; defaulting is how the check goes quietly incomplete."
        )
        stale = classified - declared
        assert not stale, f"This test classifies targets that no longer exist: {sorted(stale)}."

    def test_the_plugin_is_declared_as_a_macro_target(self) -> None:
        """A `.macro` builds for the host toolchain; a `.target` would link in."""
        blocks = _target_blocks()
        block = blocks.get(_MACRO_TARGET)
        assert block is not None, f"{_MACRO_TARGET} is not declared at all."
        assert block.lstrip().startswith(".macro("), (
            f"{_MACRO_TARGET} must be declared with `.macro(`, not "
            f"{block.lstrip()[:24]!r}. A plain target links the compiler plugin — "
            f"and SwiftSyntax with it — into the shipping product graph."
        )

    def test_the_shipping_targets_never_reach_swiftsyntax(self) -> None:
        blocks = _target_dependencies()
        unknown = _SWIFTSYNTAX_FREE_TARGETS - blocks.keys()
        assert not unknown, (
            f"This test names targets that no longer exist: {sorted(unknown)}. "
            f"Rename them here rather than letting the check quietly cover nothing."
        )

        offenders: dict[str, list[str]] = {}
        for name in sorted(_SWIFTSYNTAX_FREE_TARGETS):
            hits = [marker for marker in _SWIFTSYNTAX_MARKERS if marker in blocks[name]]
            if hits:
                offenders[name] = hits
        assert not offenders, (
            f"These shipping targets reference SwiftSyntax: {offenders}. Macros are "
            f"an optional product precisely so that probe-only consumers do not pay "
            f"SwiftSyntax build time; depending on it here removes that choice for "
            f"everyone and no Swift test can observe the loss."
        )

    def test_no_shipping_target_depends_on_the_macro_targets(self) -> None:
        blocks = _target_dependencies()
        offenders: dict[str, list[str]] = {}
        for name in sorted(_SWIFTSYNTAX_FREE_TARGETS):
            hits = [
                macro
                for macro in (_MACRO_TARGET, _MACRO_SUPPORT_TARGET)
                if re.search(rf'"{re.escape(macro)}"', blocks[name])
            ]
            if hits:
                offenders[name] = hits
        assert not offenders, (
            f"These shipping targets depend on the macro targets: {offenders}. "
            f"The dependency arrow runs one way — macro support may use the probe, "
            f"never the reverse."
        )

    def test_swiftsyntax_is_pinned_exactly(self) -> None:
        """`from:` would let a minor bump land silently on a CI machine.

        SwiftSyntax majors track the compiler (6xx -> Swift 6.x), and the plan
        names version churn as this wave's top risk, so the version is pinned
        with `exact:` and moved deliberately.
        """
        text = _manifest_text()
        assert "swift-syntax" in text, "Package.swift declares no swift-syntax dependency."
        assert re.search(r'swift-syntax[^)]*exact:\s*"\d+\.\d+\.\d+"', text), (
            "The swift-syntax dependency must be pinned with `exact:`. A range lets "
            "a toolchain-coupled dependency move under CI without a commit saying so."
        )
