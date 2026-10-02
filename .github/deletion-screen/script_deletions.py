"""Find and classify every deletion in a script (owner rule INS-18201669, CTS-E1F0D681).

Shared by the write-time gate (script-deletion-review-gate.sh) and the census
(scripts/deletion-census.py), so "is this rm screened?" has one answer:

  safe          the target is provably temporary (a literal temp path, a variable
                assigned from mktemp/mkdtemp/TemporaryDirectory or derived from
                one, pytest's tmp_path) or a build/cache directory
  reviewed      a `# DELETION-REVIEW: 1) .. 2) .. 3) .. 4) ..` comment with all four
                answers sits on one of the three lines above the deletion
  needs-review  anything else -- the reason names the target expression

Command position comes from deletion_policy's shlex segmentation, so `git rm`,
an `echo "rm -rf .."` string, comments and heredoc bodies are not deletions.
"""

from __future__ import annotations

import importlib.util
import re
from pathlib import Path
from types import ModuleType
from typing import NamedTuple

__all__ = ["Site", "classify", "language_of"]

_LIB = Path(__file__).resolve().parent
REVIEW_WINDOW = 3
BUILD_PARTS = frozenset(
    {
        "build",
        ".build",
        "dist",
        "out",
        "target",
        "node_modules",
        "__pycache__",
        "DerivedData",
        ".tox",
        ".venv",
        "venv",
        ".pytest_cache",
        ".mypy_cache",
        ".ruff_cache",
        ".cache",
        "*.pyc",
        "*.o",
    }
)
_TEMP_LITERAL = re.compile(r"^(?:/tmp/|/private/tmp/|/var/folders/|\$\{?TMPDIR\b)")
_PY_TEMP_NAMES = frozenset({"tmp_path", "tmpdir", "tmp_path_factory"})
_PY_DELETE = re.compile(r"\b(?:shutil\.rmtree|os\.remove|os\.unlink|os\.rmdir|os\.removedirs)\s*\(|\.(?:unlink|rmdir)\s*\(")
_PY_SUBPROCESS_RM = re.compile(r"""\[\s*["'](?:/bin/)?rm["']\s*,""")


class Site(NamedTuple):
    lineno: int
    line: str
    verdict: str
    reason: str


def _policy() -> ModuleType:
    spec = importlib.util.spec_from_file_location("_deletion_policy", _LIB / "deletion_policy.py")
    if spec is None or spec.loader is None:
        raise ImportError("deletion_policy.py not found beside script_deletions.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_DP = _policy()


def language_of(name: str, first_line: str) -> str | None:
    suffix = Path(name).suffix
    if suffix in (".sh", ".bash", ".zsh", ".command") or Path(name).name in ("Makefile", "makefile"):
        return "sh"
    if suffix == ".py":
        return "py"
    if not suffix and first_line.startswith("#!"):
        if "python" in first_line:
            return "py"
        if re.search(r"\b(?:ba|z|k)?sh\b", first_line):
            return "sh"
    return None


def _reviewed(lines: list[str], index: int) -> bool:
    for j in range(max(0, index - REVIEW_WINDOW), index + 1):
        text = lines[j].strip()
        if "DELETION-REVIEW:" in text and _DP.review_answers(text[text.index("#") :] if "#" in text else text):
            return True
    return False


def _is_build(expr: str) -> bool:
    parts = set(re.split(r"[/\s]+", expr.strip("\"'")))
    return bool(parts & BUILD_PARTS) or expr.endswith((".pyc", ".o"))


# ── shell ────────────────────────────────────────────────────────────────────
# An assignment anywhere on a line -- `fn() { local d="$T/x"; rm -rf "$d"; }` assigns
# after `{`, so a start-of-line anchor missed it.
_SH_ASSIGN = re.compile(
    r"""(?:^|[\s;{(&|])(?:local\s+|export\s+|readonly\s+|declare\s+)?([A-Za-z_]\w*)="""
    r"""("[^"\n]*"|'[^'\n]*'|\$\([^)\n]*\)|[^\s;&|)]+)"""
)


def _sh_temp_vars(lines: list[str]) -> set[str]:
    raw: dict[str, str] = {}
    for line in lines:
        if line.lstrip().startswith("#"):
            continue
        for name, value in _SH_ASSIGN.findall(line):
            raw.setdefault(name, value.strip().strip("\"'"))
    temp: set[str] = set()
    changed = True
    while changed:  # fixpoint: X="$T/sub" is temp once T is
        changed = False
        for name, value in raw.items():
            if name in temp:
                continue
            if "mktemp" in value or _TEMP_LITERAL.match(value) or _sh_expr_is_temp(value, temp):
                temp.add(name)
                changed = True
    return temp


def _sh_expr_is_temp(expr: str, temp_vars: set[str]) -> bool:
    expr = expr.strip("\"'")
    if _TEMP_LITERAL.match(expr):
        return True
    m = re.match(r"^\$\{?([A-Za-z_]\w*)", expr)
    return bool(m and m.group(1) in temp_vars)


def _sh_segments(line: str) -> list[list[str]]:
    """Raises ValueError on unbalanced quoting; callers must not read that as 'no rm'."""
    return _DP._segments(line)  # noqa: SLF001 -- reuse the gate's one shell segmenter


_REDIRECT = re.compile(r"^\d*(?:&?>{1,2}|<{1,2})&?\d*")


def _without_redirections(args: list[str]) -> list[str]:
    """Drop `2>/dev/null`, `> log`, `2>&1`: shlex keeps them as words, and they are not targets."""
    kept: list[str] = []
    skip_next = False
    for arg in args:
        if skip_next:
            skip_next = False
            continue
        m = _REDIRECT.match(arg)
        if m:
            skip_next = m.end() == len(arg) and not arg.endswith(tuple("0123456789"))
            continue
        kept.append(arg)
    return kept


def _find_targets(args: list[str]) -> list[str]:
    roots = [a for a in args[: args.index("-delete")] if not a.startswith("-")][:1]
    named = "-name" in args or "-iname" in args
    return ["*.pyc"] if named and any(_is_build(a) for a in args) else roots or ["."]


def _trap_targets(body: str) -> list[str]:
    found: list[str] = []
    for seg in _sh_segments(body):
        found += _sh_targets(seg) or []
    return found


def _sh_targets(segment: list[str]) -> list[str] | None:
    """Deletion targets of one command, [] for a target-less rm, None if not a deletion."""
    verb, args = _DP._verb(segment)  # noqa: SLF001 -- reuse the gate's one verb parser
    if verb == "rm":
        return _without_redirections([a for a in args if not a.startswith("-")])
    if verb == "find" and "-delete" in args:
        return _find_targets(args)
    if verb == "trap" and args:
        return _trap_targets(args[0]) or None
    return None


def _classify_sh(text: str) -> list[Site]:
    stripped = _DP._strip_heredocs(text)  # noqa: SLF001
    lines = text.splitlines()
    kept = set(stripped.splitlines())
    temp_vars = _sh_temp_vars(lines)
    sites: list[Site] = []
    in_heredoc = False
    terminator = ""
    i = -1
    while i + 1 < len(lines):
        i += 1
        line = lines[i]
        if in_heredoc:
            in_heredoc = line.strip() != terminator
            continue
        heredoc = re.search(r"<<-?\s*['\"]?([A-Za-z_]\w*)", line)
        if heredoc:
            in_heredoc, terminator = True, heredoc.group(1)
        if line.lstrip().startswith("#") or line not in kept:
            continue
        start = i
        while line.endswith("\\") and i + 1 < len(lines):  # a `\` continuation is one command
            i += 1
            line = line[:-1] + " " + lines[i]
        try:
            segments = _sh_segments(line)
        except ValueError:
            # Unparseable quoting is not "no deletion": a line that spells rm is reviewed.
            if re.search(r"(?:^|[;&|(\s])(?:/bin/)?rm\s", line):
                sites.append(_verdict(lines, start, ["(unparseable line)"]))
            continue
        for segment in segments:
            got = _sh_targets(segment)
            if got is None:
                continue
            targets = got or ["(no target)"]
            unsafe = [t for t in targets if not (_sh_expr_is_temp(t, temp_vars) or _is_build(t))]
            sites.append(_verdict(lines, start, unsafe))
    return sites


# ── python ───────────────────────────────────────────────────────────────────
def _py_temp_vars(lines: list[str]) -> set[str]:
    temp = set(_PY_TEMP_NAMES)
    assigned: list[tuple[str, str]] = []
    for line in lines:
        m = re.match(r"\s*([A-Za-z_]\w*)\s*(?::[^=\n]+)?=\s*(.*)$", line)
        if m and not m.group(2).startswith("="):
            assigned.append((m.group(1), m.group(2)))
            if re.search(r"mkdtemp|mkstemp|TemporaryDirectory|gettempdir|tmp_path", m.group(2)):
                temp.add(m.group(1))
        for name in re.findall(r"TemporaryDirectory\([^)\n]*\)\s+as\s+([A-Za-z_]\w*)", line):
            temp.add(name)
    changed = True
    while changed:  # fixpoint: `path = tmp_path / "x"` makes path temp, and so on
        changed = False
        for name, expr in assigned:
            if name not in temp and set(re.findall(r"[A-Za-z_]\w*", expr)) & temp:
                temp.add(name)
                changed = True
    return temp


def _py_code(line: str) -> str:
    """The line with string literals and a trailing comment removed."""
    no_strings = re.sub(r"""("[^"\n]*"|'[^'\n]*')""", '""', line)
    return no_strings.split("#", 1)[0]


def _classify_py(text: str) -> list[Site]:
    lines = text.splitlines()
    temp_vars = _py_temp_vars(lines)
    sites: list[Site] = []
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#"):
            continue
        code = _py_code(line)
        if _PY_SUBPROCESS_RM.search(line) and not line.lstrip().startswith(("print(", "log")):
            sites.append(_verdict(lines, i, [line.strip()]))
            continue
        m = _PY_DELETE.search(code)
        if not m:
            continue
        args = line[m.end() :]
        head = re.split(r"[,)]", args, maxsplit=1)[0].strip()
        if m.group(0).startswith("."):
            head = code[: m.start()].split("(")[-1].strip() or code[: m.start()].strip()
        names = set(re.findall(r"[A-Za-z_]\w*", head))
        safe = bool(names & temp_vars) or _is_build(head) or _TEMP_LITERAL.match(head.strip("\"'") or "x")
        sites.append(_verdict(lines, i, [] if safe else [head or line.strip()]))
    return sites


def _verdict(lines: list[str], index: int, unsafe: list[str]) -> Site:
    line = lines[index].strip()
    if not unsafe:
        return Site(index + 1, line, "safe", "temporary or build/cache target")
    if _reviewed(lines, index):
        return Site(index + 1, line, "reviewed", "DELETION-REVIEW above")
    return Site(index + 1, line, "needs-review", f"target not provably temporary: {', '.join(unsafe)}")


def classify(text: str, lang: str) -> list[Site]:
    return _classify_sh(text) if lang == "sh" else _classify_py(text)
