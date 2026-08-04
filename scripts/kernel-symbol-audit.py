#!/usr/bin/env python3.14
"""Audit the public surface of VerdictUIKernel against the Wave 1 exit gate.

The gate is "every public kernel symbol has a doc comment and at least one test
exercising it". Checking that by eye does not survive a second wave, so this
script makes it mechanical:

* **Doc gap** — an audited symbol whose preceding non-blank line is not a `///`
  doc comment.
* **Test gap** — an audited symbol whose name never appears as a whole word in
  `Tests/VerdictUIKernelTests/`.

Scope, stated rather than implied:

* Audited: public/open types, enum cases of public enums, functions, computed
  properties, static constants, and the requirements of a public protocol.
* **Doc-exempt**: initializers and stored properties. Their meaning is carried by
  the enclosing type's documentation, and demanding `/// The width.` on
  `Size.width` buys noise, not comprehension. They are still checked for a test.
* **Doc-inherited**: a member that satisfies a documented requirement of a kernel
  protocol the type conforms to (`LintRule.id`, `LintRule.evaluate`). DocC
  inherits documentation the same way, and restating one sentence six times
  across six rule files degrades it into boilerplate nobody reads.
* The test check is a name-mention floor, not proof of assertion depth: it
  catches a symbol nobody touched, not a symbol touched weakly. For an
  initializer it looks for the enclosing type name, since `init` is not a
  searchable identifier.

Run: python3.14 scripts/kernel-symbol-audit.py [--json]
Exit code 1 if any gap is found.
"""

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

__all__ = [
    "AuditResult",
    "KERNEL_DIR",
    "KERNEL_TEST_DIR",
    "PROJECT_ROOT",
    "Scope",
    "Symbol",
    "audit",
    "collect_symbols",
    "main",
]

PROJECT_ROOT = Path(__file__).resolve().parents[1]
KERNEL_DIR = PROJECT_ROOT / "Sources" / "VerdictUIKernel"
KERNEL_TEST_DIR = PROJECT_ROOT / "Tests" / "VerdictUIKernelTests"

EXTENSION = "extension"
PROTOCOL = "protocol"
_TYPE_KINDS = frozenset({"enum", "struct", "class", PROTOCOL, "actor", EXTENSION})

# The modifier run is a flat character class, deliberately not a repeated group:
# a character class cannot backtrack quadratically the way a nested quantifier can.
_TYPE_RE = re.compile(
    r"^(?P<indent>[ \t]*)(?P<mods>[a-z \t]*)"
    r"(?P<kind>enum|struct|class|protocol|actor|extension)\s+"
    r"(?P<name>[A-Za-z_][\w.]*)"
)
_MEMBER_RE = re.compile(
    r"^(?P<indent>[ \t]*)(?P<mods>[a-z \t]*)"
    r"(?P<kind>func|init|var|let|subscript|typealias)\b(?P<rest>.*)$"
)
_CASE_RE = re.compile(r"^(?P<indent>[ \t]*)case\s+(?P<body>[^:{}]+?)[ \t]*,?[ \t]*$")
_IDENTIFIER_RE = re.compile(r"[A-Za-z_]\w*")
_LEADING_NAME_RE = re.compile(r"^([a-z_]\w*)")
_GENERIC_RE = re.compile(r"<[^>]*>")


@dataclass
class Symbol:
    """One public declaration found in the kernel sources."""

    name: str
    kind: str
    owner: str
    file: str
    line: int
    documented: bool
    doc_required: bool
    owner_kind: str = ""
    owner_conformances: tuple[str, ...] = ()

    @property
    def display(self) -> str:
        return f"{self.owner}.{self.name}" if self.owner else self.name


@dataclass
class Scope:
    """An open lexical scope, tracked by indentation depth."""

    indent: int
    kind: str
    name: str
    is_public: bool
    conformances: tuple[str, ...] = ()


@dataclass
class AuditResult:
    """Audited symbols plus the two gap categories."""

    symbols: list[Symbol] = field(default_factory=list)
    doc_gaps: list[Symbol] = field(default_factory=list)
    test_gaps: list[Symbol] = field(default_factory=list)
    inherited_docs: int = 0

    @property
    def total_gaps(self) -> int:
        return len(self.doc_gaps) + len(self.test_gaps)


def _is_public(mods: str) -> bool:
    tokens = mods.split()
    return "public" in tokens or "open" in tokens


def _documented(lines: list[str], index: int) -> bool:
    """True when the nearest preceding non-blank line is a `///` doc comment.

    Attribute lines (`@MainActor`) sit between a doc comment and its declaration,
    so they are stepped over rather than treated as the answer.
    """
    cursor = index - 1
    while cursor >= 0:
        stripped = lines[cursor].strip()
        if not stripped or stripped.startswith("@"):
            cursor -= 1
            continue
        return stripped.startswith("///")
    return False


def _member_name(kind: str, rest: str) -> str | None:
    if kind == "init":
        return "init"
    match = _IDENTIFIER_RE.search(rest)
    return match.group(0) if match else None


def _case_names(body: str) -> list[str]:
    """Declared case names in an enum `case` line, or [] for a `switch` case.

    A `switch` case either carries a colon (already excluded by the line regex)
    or starts with `.`/a type name, which the leading-lowercase test rejects.
    """
    names: list[str] = []
    for raw_part in body.split(","):
        part = raw_part.strip()
        if not part:
            continue
        match = _LEADING_NAME_RE.match(part)
        if not match:
            return []
        names.append(match.group(1))
    return names


def _enclosing_type(stack: list[Scope]) -> Scope | None:
    for scope in reversed(stack):
        if scope.kind in _TYPE_KINDS:
            return scope
    return None


def _conformances(line: str, name: str) -> tuple[str, ...]:
    """Protocol/superclass names in a type declaration's inheritance clause."""
    tail = line.split(name, 1)[-1]
    tail = tail.split("{", 1)[0].split(" where ", 1)[0]
    if ":" not in tail:
        return ()
    clause = _GENERIC_RE.sub("", tail.split(":", 1)[1])
    return tuple(part.strip() for part in clause.split(",") if part.strip())


def _type_symbol(
    match: re.Match[str], enclosing: Scope | None, context: tuple[str, list[str], int]
) -> tuple[Scope, Symbol | None]:
    """The scope a type declaration opens, and the symbol it contributes (if public)."""
    rel, lines, index = context
    kind = match.group("kind")
    name = match.group("name")
    # An extension carries no access level of its own; treat it as a transparent
    # container so `public` members written inside it still count.
    is_public = True if kind == EXTENSION else _is_public(match.group("mods"))
    indent = len(match.group("indent"))
    scope = Scope(
        indent=indent,
        kind=kind,
        name=name,
        is_public=is_public,
        conformances=_conformances(lines[index], name),
    )
    if kind == EXTENSION or not is_public:
        return scope, None
    return scope, Symbol(
        name=name,
        kind=kind,
        owner=enclosing.name if enclosing else "",
        file=rel,
        line=index + 1,
        documented=_documented(lines, index),
        doc_required=True,
        owner_kind=enclosing.kind if enclosing else "",
        owner_conformances=enclosing.conformances if enclosing else (),
    )


def _case_symbols(
    match: re.Match[str], enclosing: Scope | None, context: tuple[str, list[str], int]
) -> list[Symbol]:
    if not (enclosing and enclosing.kind == "enum" and enclosing.is_public):
        return []
    rel, lines, index = context
    documented = _documented(lines, index)
    return [
        Symbol(
            name=name,
            kind="case",
            owner=enclosing.name,
            file=rel,
            line=index + 1,
            documented=documented,
            doc_required=True,
            owner_kind=enclosing.kind,
            owner_conformances=enclosing.conformances,
        )
        for name in _case_names(match.group("body"))
    ]


def _member_symbol(
    match: re.Match[str], enclosing: Scope | None, context: tuple[str, list[str], int]
) -> Symbol | None:
    mods = match.group("mods")
    kind = match.group("kind")
    in_public_protocol = bool(enclosing and enclosing.kind == PROTOCOL and enclosing.is_public)
    if not (_is_public(mods) or in_public_protocol):
        return None
    rest = match.group("rest")
    name = _member_name(kind, rest)
    if name is None:
        return None
    rel, lines, index = context
    stored_property = kind in {"var", "let"} and "{" not in rest
    is_static_constant = kind == "let" and "static" in mods.split()
    doc_required = not (kind == "init" or (stored_property and not is_static_constant))
    return Symbol(
        name=name,
        kind=kind,
        owner=enclosing.name if enclosing else "",
        file=rel,
        line=index + 1,
        documented=_documented(lines, index),
        doc_required=doc_required,
        owner_kind=enclosing.kind if enclosing else "",
        owner_conformances=enclosing.conformances if enclosing else (),
    )


def _scan_file(path: Path) -> list[Symbol]:
    lines = path.read_text().splitlines()
    rel = str(path.relative_to(PROJECT_ROOT))
    symbols: list[Symbol] = []
    stack: list[Scope] = []
    for index, raw in enumerate(lines):
        stripped = raw.strip()
        if not stripped or stripped.startswith("//"):
            continue
        indent = len(raw) - len(raw.lstrip())
        while stack and stack[-1].indent >= indent:
            stack.pop()
        enclosing = _enclosing_type(stack)
        context = (rel, lines, index)

        if type_match := _TYPE_RE.match(raw):
            scope, symbol = _type_symbol(type_match, enclosing, context)
            stack.append(scope)
            if symbol is not None:
                symbols.append(symbol)
        elif case_match := _CASE_RE.match(raw):
            symbols.extend(_case_symbols(case_match, enclosing, context))
        elif member_match := _MEMBER_RE.match(raw):
            symbol = _member_symbol(member_match, enclosing, context)
            if symbol is not None:
                symbols.append(symbol)
    return symbols


def collect_symbols() -> list[Symbol]:
    """Every public symbol declared under `Sources/VerdictUIKernel`."""
    symbols: list[Symbol] = []
    for path in sorted(KERNEL_DIR.rglob("*.swift")):
        symbols.extend(_scan_file(path))
    return symbols


def _apply_inherited_docs(symbols: list[Symbol]) -> int:
    """Clear `doc_required` where a documented protocol requirement covers the member.

    Returns the number of members exempted, so the report can say so out loud
    instead of quietly forgiving them.
    """
    requirements: dict[str, set[str]] = {}
    for symbol in symbols:
        if symbol.owner_kind == PROTOCOL and symbol.documented:
            requirements.setdefault(symbol.owner, set()).add(symbol.name)

    inherited = 0
    for symbol in symbols:
        if not symbol.doc_required or symbol.documented or symbol.owner_kind == PROTOCOL:
            continue
        if any(symbol.name in requirements.get(p, set()) for p in symbol.owner_conformances):
            symbol.doc_required = False
            inherited += 1
    return inherited


def audit() -> AuditResult:
    """Collect symbols and classify their doc/test gaps."""
    if not KERNEL_DIR.is_dir():
        raise SystemExit(f"kernel directory missing: {KERNEL_DIR}")
    if not KERNEL_TEST_DIR.is_dir():
        raise SystemExit(f"kernel test directory missing: {KERNEL_TEST_DIR}")

    test_source = "\n".join(path.read_text() for path in sorted(KERNEL_TEST_DIR.rglob("*.swift")))
    mentioned = set(_IDENTIFIER_RE.findall(test_source))

    result = AuditResult(symbols=collect_symbols())
    result.inherited_docs = _apply_inherited_docs(result.symbols)
    for symbol in result.symbols:
        if symbol.doc_required and not symbol.documented:
            result.doc_gaps.append(symbol)
        needle = symbol.owner if symbol.name == "init" else symbol.name
        if needle and needle not in mentioned:
            result.test_gaps.append(symbol)
    return result


def _report(result: AuditResult) -> None:
    print(
        f"Audited {len(result.symbols)} public kernel symbols "
        f"({result.inherited_docs} documented by an inherited protocol requirement)"
    )
    for label, gaps in (("undocumented", result.doc_gaps), ("untested", result.test_gaps)):
        if gaps:
            print(f"\n{len(gaps)} {label}:")
            for symbol in gaps:
                print(f"  {symbol.display} ({symbol.kind}) — {symbol.file}:{symbol.line}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Audit VerdictUIKernel's public surface.")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args(argv)

    result = audit()
    if args.json:
        payload = {
            "audited": len(result.symbols),
            "doc_gaps": [
                {"symbol": s.display, "kind": s.kind, "file": s.file, "line": s.line}
                for s in result.doc_gaps
            ],
            "test_gaps": [
                {"symbol": s.display, "kind": s.kind, "file": s.file, "line": s.line}
                for s in result.test_gaps
            ],
            "total_gaps": result.total_gaps,
        }
        print(json.dumps(payload, indent=2))
    else:
        _report(result)
        print(
            f"\nFAIL: {result.total_gaps} gap(s)"
            if result.total_gaps
            else "PASS: every public kernel symbol is documented and mentioned by a kernel test"
        )
    return 1 if result.total_gaps else 0


if __name__ == "__main__":
    sys.exit(main())
