#!/usr/bin/env python3
"""Remove Lua comments from a source file, keeping every line number.

Why this exists
---------------
The shipped plugin carries about 159 KB of comments in main.lua alone, which
is 39% of that file. They are worth keeping in the repository and not worth
downloading 52 times over in a release zip.

Why line numbers survive
------------------------
KOReader reports an error as `main.lua:5714`. If the stripper deleted comment
lines, every such report would point at the wrong line of the source in the
repository, and a bug report from a user would be much harder to act on. So a
comment is replaced by nothing, but each newline INSIDE it is kept. The output
therefore has the same number of lines as the input, and line N still holds the
same statement. Runs of blank lines cost almost nothing in the zip.

What is kept
------------
The leading comment block, so the file still says what it is. Pass
--no-header to drop that too.

Safety
------
A comment marker inside a string is not a comment. `local s = "--[[ x ]]"` and
`local p = [[a -- b]]` must survive untouched, so this walks the source with a
small Lua lexer rather than a regular expression. Verify the result with
--check: it compiles both files and compares the bytecode. Comments never
reach the bytecode, and line numbers do, so identical bytecode proves the strip
changed no token and moved no line.

Usage
-----
    strip_comments.py SRC DST            strip SRC into DST
    strip_comments.py --check SRC DST    compare the bytecode of the two
"""

import os
import shutil
import subprocess
import sys
import tempfile


def _long_bracket(src, i):
    """Length of a long bracket `[==[` opening at i, or 0 if there is none."""
    if src[i] != "[":
        return 0
    j = i + 1
    while j < len(src) and src[j] == "=":
        j += 1
    if j < len(src) and src[j] == "[":
        return j + 1 - i          # includes both brackets and the = run
    return 0


def strip(src, keep_header=True):
    out = []
    i, n = 0, len(src)
    seen_code = False             # has any non-comment token appeared yet?
    while i < n:
        c = src[i]

        # ── comment ──────────────────────────────────────────────────────
        if c == "-" and src.startswith("--", i):
            opener = _long_bracket(src, i + 2)
            if opener:
                level = opener - 2                    # number of = signs
                close = "]" + "=" * level + "]"
                end = src.find(close, i + 2 + opener)
                end = n if end < 0 else end + len(close)
            else:
                end = src.find("\n", i)
                end = n if end < 0 else end           # the \n itself is code
            block = src[i:end]
            if keep_header and not seen_code:
                out.append(block)                     # the file's own header
            else:
                # Drop the indent or the gap the comment leaves behind, so
                # `x = 1  -- why` becomes `x = 1`, not `x = 1  `. Only plain
                # code appends a bare " " or "\t" as its own element, so this
                # can never reach inside a string literal.
                while out and out[-1] in (" ", "\t"):
                    out.pop()
                out.append("\n" * block.count("\n"))  # keep the line count
            i = end
            continue

        # ── short string ─────────────────────────────────────────────────
        if c in "\"'":
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == c:
                    j += 1
                    break
                if src[j] == "\n":                    # unterminated: bail out
                    break
                j += 1
            out.append(src[i:j])
            i = j
            seen_code = True
            continue

        # ── long string ──────────────────────────────────────────────────
        opener = _long_bracket(src, i)
        if opener:
            level = opener - 2
            close = "]" + "=" * level + "]"
            end = src.find(close, i + opener)
            end = n if end < 0 else end + len(close)
            out.append(src[i:end])
            i = end
            seen_code = True
            continue

        # ── plain code ───────────────────────────────────────────────────
        out.append(c)
        if not c.isspace():
            seen_code = True
        i += 1

    # No global rstrip here on purpose: a long string can hold a line that ENDS
    # in a space, and trimming it would change the string's value. The gap a
    # comment leaves behind is removed above, where a string is never in reach.
    return "".join(out)


def compiled(paths):
    """Compile each file and return the bytecode, debug info included, or None
    if luac is missing. Line numbers live in the debug info, so two files that
    compile to the same bytes hold the same tokens on the same lines.

    luac writes the SOURCE PATH into the debug info, so every file is compiled
    through ONE shared path. Give each its own temporary name and the
    comparison fails on the name alone and proves nothing."""
    d = tempfile.mkdtemp()
    src = os.path.join(d, "chunk.lua")
    out = os.path.join(d, "chunk.out")
    try:
        result = []
        for path in paths:
            shutil.copyfile(path, src)
            r = subprocess.run(["luac", "-o", out, src],
                               capture_output=True, text=True)
            if r.returncode != 0:
                raise SystemExit(f"luac failed on {path}:\n{r.stderr}")
            with open(out, "rb") as f:
                result.append(f.read())
        return result
    except FileNotFoundError:
        return None
    finally:
        shutil.rmtree(d, ignore_errors=True)


def main(argv):
    check = "--check" in argv
    keep_header = "--no-header" not in argv
    args = [a for a in argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        raise SystemExit(__doc__)
    src_path, dst_path = args

    if check:
        both = compiled([src_path, dst_path])
        if both is None:
            print("luac not found: skipping the bytecode check")
            return 0
        a, b = both
        if a != b:
            raise SystemExit(
                f"BYTECODE DIFFERS: {src_path} vs {dst_path}. "
                "The strip changed a token or moved a line.")
        print(f"bytecode identical ({len(a)} bytes): "
              f"{src_path} == {dst_path}")
        return 0

    with open(src_path, encoding="utf-8") as f:
        src = f.read()
    dst = strip(src, keep_header)
    if src.count("\n") != dst.count("\n"):
        raise SystemExit(
            f"line count changed: {src.count(chr(10))} -> {dst.count(chr(10))}")
    with open(dst_path, "w", encoding="utf-8") as f:
        f.write(dst)
    saved = len(src.encode()) - len(dst.encode())
    print(f"  {src_path}: {len(src) // 1024} KB -> {len(dst) // 1024} KB "
          f"({saved // 1024} KB of comments removed, "
          f"{src.count(chr(10)) + 1} lines kept)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
