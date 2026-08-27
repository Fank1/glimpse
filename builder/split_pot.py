#!/usr/bin/env python3
"""Split the extracted glimpse.pot into two translation components.

Rationale: of the ~165 translatable strings, ~113 are short UI labels
(~316 words) and ~52 are long long-press help texts (~1000 words) — so the
help texts are ~75% of the effort for supplementary prose. Splitting them
lets a language become fully usable after roughly an hour on the labels,
instead of showing "30% translated" (which reads as abandoned) until
someone grinds through the explainers. gettext falls back per string, so
untranslated help text simply shows in English.

Routing rule: a string belongs to the help component if EVERY one of its
source references sits on a `help_text =` assignment in main.lua. Strings
shared between a label and a help text stay in labels (the required set).

Writes:  templates/glimpse-labels.pot
         templates/glimpse-help.pot
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
POT = ROOT / "plugin/l10n/templates/glimpse.pot"
MAIN = ROOT / "plugin/main.lua"
OUT_LABELS = ROOT / "plugin/l10n/templates/glimpse-labels.pot"
OUT_HELP = ROOT / "plugin/l10n/templates/glimpse-help.pot"


def help_text_lines(main_src: str) -> set:
    """Line numbers in main.lua carrying long-press explainer prose.

    Two shapes count as help text:
      1. `help_text = _("…")` — the menu-item explainers.
      2. entries of the `local cat_help = { … }` table — the per-unit-category
         explainers, which are help_text values assigned indirectly
         (`help_text = cat_help[key]`) and so never match shape 1.

    xgettext reports the line the STRING starts on; both shapes keep the
    string on the assignment line, but we also accept the following line for
    the case where the assignment opens and the string begins below it.
    """
    lines = main_src.split("\n")
    out = set()
    in_cat_help = False
    for i, line in enumerate(lines, 1):
        if re.match(r"\s*local\s+cat_help\s*=\s*\{", line):
            in_cat_help = True
            continue
        if in_cat_help:
            if re.match(r"\s*\}", line):
                in_cat_help = False
            else:
                out.add(i)
            continue
        if re.search(r"\bhelp_text_func\s*=\s*function", line):
            # Shape 3: `help_text_func = function() … end`. The menu entry
            # picks its explainer at draw time (the auto-convert toggle says
            # something different in the in-text modes), so the strings sit
            # several lines INSIDE the function body rather than on the
            # assignment line — the line-based shapes above miss them all.
            #
            # Getting this wrong is not cosmetic: without it a 50-word
            # explainer lands in the labels component, which is the set a
            # translator is asked to finish first precisely because it is
            # short. It also silently DRAGGED an existing help string out of
            # the help component when its entry was converted to _func.
            indent = len(line) - len(line.rstrip("\n").lstrip())
            out.add(i)
            j = i
            while j < len(lines):
                nxt = lines[j]
                out.add(j + 1)
                stripped = nxt.strip()
                if (stripped == "end," or stripped == "end") \
                   and (len(nxt) - len(nxt.lstrip())) <= indent:
                    break
                j += 1
            continue
        if re.search(r"\bhelp_text\s*=", line):
            out.add(i)
            # `help_text =` alone on its line, string on the next.
            if not re.search(r"\bhelp_text\s*=\s*\S", line):
                out.add(i + 1)
    return out


def split_entries(pot_src: str):
    """Yield (header, [entry_block, ...]) split on blank lines."""
    blocks = pot_src.split("\n\n")
    header, entries = blocks[0], [b for b in blocks[1:] if b.strip()]
    return header, entries


def main() -> int:
    if not POT.exists():
        print(f"missing {POT} — run builder/build_l10n.sh first", file=sys.stderr)
        return 1
    pot_src = POT.read_text(encoding="utf-8")
    helplines = help_text_lines(MAIN.read_text(encoding="utf-8"))
    header, entries = split_entries(pot_src)

    labels, helps = [], []
    for block in entries:
        refs = []
        for m in re.finditer(r"^#:(.+)$", block, re.M):
            for ref in m.group(1).split():
                lm = re.match(r"main\.lua:(\d+)$", ref.strip())
                if lm:
                    refs.append(int(lm.group(1)))
        # Only route to help when every reference is a help_text site;
        # a string used for both stays in the required labels set.
        if refs and all(r in helplines for r in refs):
            helps.append(block)
        else:
            labels.append(block)

    # Drop the "#: main.lua:NNNN" references on the way out. They have done
    # their job by this point — the routing above is the only thing that reads
    # them — and these two files are the ones Crowdin syncs (crowdin.yml), so
    # anything that changes here starts a round trip. Line numbers shift on
    # every scanner release, which made the templates look modified when no
    # string had changed: Crowdin then regenerated all 58 languages and opened
    # a pull request with no translation work in it, and msgmerge rewrote all
    # 116 .po to match. v1.8.2 churned 119 files that way. Stripping them makes
    # a pure line shift a no-op while a real string change still comes through.
    # Translators lose nothing: every string is in main.lua, so the line number
    # was all "#:" carried, and Crowdin shows the "#. TRANSLATORS:" comments.
    def without(text: str, prefix: str) -> str:
        return "\n".join(l for l in text.split("\n") if not l.startswith(prefix))

    for path, blocks, what in (
        (OUT_LABELS, labels, "labels"),
        (OUT_HELP, helps, "help texts"),
    ):
        text = (header.rstrip() + "\n\n"
                + "\n\n".join(without(b, "#:").strip() for b in blocks) + "\n")
        # Keep the existing file when only POT-Creation-Date differs. The header
        # is copied from the master template, which IS regenerated on every line
        # shift (it still carries the locations this router needs), so without
        # this the date alone would change these two files — and these two are
        # Crowdin's sources, so that restarts the same round trip the
        # reference-stripping above exists to end. build_l10n.sh guards the
        # master the same way; this is that guard applied one level down.
        stamp = '"POT-Creation-Date:'
        if path.exists() and without(path.read_text(encoding="utf-8"), stamp) \
                          == without(text, stamp):
            print(f"  {len(blocks):>3} {what:<11} -> {path.name} (unchanged)")
            continue
        path.write_text(text, encoding="utf-8")
        print(f"  {len(blocks):>3} {what:<11} -> {path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
