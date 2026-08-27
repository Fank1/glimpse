#!/usr/bin/env python3
"""Fail the build if a `_` binding shadows the gettext module in the same scope.

`_` is gettext (`local _ = require("gettext")` at the top of main.lua), but it
is ALSO Lua's conventional throwaway name — `local _, x = f()`,
`for _, v in ipairs(t)`. Where the two overlap, `_("…")` or `_.ngettext(…)`
indexes whatever the discard holds and the reader dies at runtime:

    main.lua:6389: attempt to index local '_' (a number value)
        in function '_scanNoticeText'

`luac -p` cannot see this — it's valid Lua. It only surfaces when that exact
branch runs, which for the real case above meant "a scan finishing in a book
already converted in mode 2/3". This walks scopes statically instead.

Usage:  python3 builder/check_gettext_shadow.py [file.lua …]
Exit 0 = clean, 1 = a shadowed use (prints binding and use sites).
"""

from __future__ import annotations
import re
import sys
from pathlib import Path

ROOT = Path(__file__).parent.parent
DEFAULT = [ROOT / "plugin" / "main.lua"]

# `for`/`while` are always closed by their own `do`, so counting both would
# double-count — count `do` and let it stand for the loop.
OPEN = re.compile(r"(?<![\w])(?:function|if|do)(?![\w])")
CLOSE = re.compile(r"(?<![\w])end(?![\w])")
# `_` used as a value: `_(` or `_.` — never part of `_FOO` or `foo_`.
USE = re.compile(r"(?<![\w])_(?=\s*[\(\.])")
BIND_LOCAL = re.compile(r"(?<![\w])local\s+_\s*[,=]")
BIND_LOOP = re.compile(r"(?<![\w])for\s+_\s*,")


def strip(line: str) -> str:
    """Remove comments and string literals so their contents can't be counted."""
    line = re.sub(r"\[\[.*?\]\]", '""', line)
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    line = re.sub(r"'(?:[^'\\]|\\.)*'", '""', line)
    return re.sub(r"--.*$", "", line)


def scope_end(lines: list[str], start: int, is_local: bool) -> int:
    """Last line on which a `_` bound at `start` is still in scope.

    A loop variable lives inside the loop body; a `local` lives until its
    ENCLOSING block closes, i.e. until depth first goes negative.
    """
    depth = 0
    if is_local:
        for i in range(start, len(lines)):
            l = strip(lines[i])
            depth += len(OPEN.findall(l)) - len(CLOSE.findall(l))
            if depth < 0:
                return i
        return len(lines) - 1
    entered = False
    for i in range(start, len(lines)):
        l = strip(lines[i])
        depth += len(OPEN.findall(l)) - len(CLOSE.findall(l))
        if entered and depth <= 0:
            return i
        if depth > 0:
            entered = True
        elif not entered:
            return i  # single-line `for … do … end`
    return len(lines) - 1


def check(path: Path) -> list[str]:
    lines = path.read_text(encoding="utf-8").split("\n")
    problems = []
    for i, raw in enumerate(lines):
        line = strip(raw)
        is_local = bool(BIND_LOCAL.search(line))
        if not is_local and not BIND_LOOP.search(line):
            continue
        if "require(\"gettext\")" in raw:
            continue  # the definition itself
        end = scope_end(lines, i, is_local)
        for j in range(i + 1, min(end + 1, len(lines))):
            if USE.search(strip(lines[j])):
                problems.append(
                    f"{path.name}:{i+1}: `_` bound here shadows gettext\n"
                    f"    {raw.strip()[:88]}\n"
                    f"{path.name}:{j+1}: …and gettext is used while shadowed\n"
                    f"    {lines[j].strip()[:88]}\n"
                    f"  Fix: rename the throwaway (e.g. `_ver`, `_idx`), never `_`.")
                break
    return problems


def main() -> int:
    paths = [Path(a) for a in sys.argv[1:]] or DEFAULT
    problems = [p for path in paths for p in check(path)]
    if problems:
        print(f"FAIL — {len(problems)} gettext shadowing bug(s):\n")
        for p in problems:
            print(p + "\n")
        return 1
    print(f"  no `_` shadows gettext in {', '.join(p.name for p in paths)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
