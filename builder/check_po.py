#!/usr/bin/env python3
"""Check translated .po files for the errors that break the UI in any language.

None of these checks need knowledge of the language being checked, which is the
point: the maintainer can't read most of the 58 locales, and neither can any
single translator. What CAN be verified mechanically is that a translation
still fits the machine contract the string has with the code.

What it checks, and why each one is here:

  placeholders   %1/%2 must appear in the translation exactly as often as in
                 the source. Reordering is fine and expected (word order
                 differs); dropping one means the value never renders, and
                 inventing one renders literal text. Glimpse builds these
                 with ffiutil.template, which does NOT error on a missing
                 placeholder — it just silently omits the value.

  plural forms   A .po declares nplurals in its Plural-Forms header. If the
                 file supplies fewer msgstr[N] than it declares, msgfmt is
                 happy but the missing form renders empty at runtime for
                 exactly the counts that select it — so Polish n=25 shows a
                 blank where a number should be.

  edge space     "The hallway was " and " wide." are sentence fragments that
                 wrap a measurement. A translator (or an editor that trims on
                 save) dropping the edge space produces "The hallway was1.8 m".
                 Invisible in review, obvious on the device.

  unit symbols   m, km, kg, °C are SI and identical in every language;
                 plugin/l10n/README.md tells translators not to touch them.
                 A "translated" unit symbol is a wrong measurement, and this is
                 written into the reader's own book file in modes 2 and 3.

  source-equal   A file where nearly every msgstr equals its msgid is the
                 signature of Crowdin's "Skip untranslated strings" export
                 setting being OFF — it pads untranslated strings with the
                 English source, so a language at 5% arrives looking finished.
                 A ratio, not a rule: a few strings legitimately translate to
                 themselves ("Metric" is "Metric" in Swedish).

  length         E-reader buttons truncate silently rather than wrapping. A
                 label several times longer than its source is a warning, not
                 an error — German is simply long — but worth a look.

  msgfmt -c      The compiler's own checks, if msgfmt is installed.

Usage:
    python3 builder/check_po.py                  # every plugin/l10n/<lang>/*.po
    python3 builder/check_po.py de fr            # only these locales
    python3 builder/check_po.py --warnings-fail  # treat warnings as errors

Exit 0 = no errors, 1 = at least one error.
"""

from __future__ import annotations
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).parent.parent
L10N = ROOT / "plugin" / "l10n"

# Symbols that must survive translation untouched, split by how safely they can
# be recognised.
#
# Most unit symbols are also ordinary English words or single letters — "in",
# "m", "st", "l", "g". Looking for them as bare tokens makes the check useless:
# "Converted %1 unit in book" contains "in", so every correct translation would
# be reported as having lost a unit. So they only count when attached to a
# number, exactly as the plugin's own scanner requires ("5 ft 11 in", "1.8 m",
# "75 kg") — which is also the only place losing one would be a wrong
# measurement rather than a wording choice.
#
# The degree symbols and km/h can't collide with a word, so they're checked
# wherever they appear.
UNITS_ANYWHERE = ["°C", "°F", "km/h"]
UNITS_AFTER_NUMBER = ["km", "kg", "ml", "mm", "cm", "st", "lb", "oz",
                      "ft", "in", "mi", "m", "g", "l"]

LENGTH_WARN_RATIO = 2.6      # msgstr this many times longer than msgid
LENGTH_WARN_MIN = 14         # ...and at least this long, so short words are exempt
SOURCE_EQUAL_WARN = 0.85     # fraction of entries identical to their source


def unquote(line: str) -> str:
    m = re.search(r'"((?:[^"\\]|\\.)*)"', line)
    return "" if m is None else m.group(1)


def parse_po(path: Path) -> tuple[list[dict], dict]:
    """Minimal PO reader: entries plus the header as a dict. No dependencies."""
    entries: list[dict] = []
    cur: dict = {}
    key = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#~"):
            if not line and cur:
                entries.append(cur)
                cur, key = {}, None
            continue
        if line.startswith("#"):
            continue
        m = re.match(r'(msgctxt|msgid_plural|msgid|msgstr(?:\[\d+\])?)\s+"', line)
        if m:
            key = m.group(1)
            cur[key] = unquote(line)
        elif line.startswith('"') and key:
            cur[key] += unquote(line)
    if cur:
        entries.append(cur)

    header: dict = {}
    for e in entries:
        if e.get("msgid") == "":
            for part in e.get("msgstr", "").split("\\n"):
                if ":" in part:
                    k, v = part.split(":", 1)
                    header[k.strip()] = v.strip()
            break
    return [e for e in entries if e.get("msgid")], header


def placeholders(text: str) -> list[str]:
    return sorted(re.findall(r"%\d", text))


def units_in(text: str) -> set[str]:
    found = set()
    for u in UNITS_ANYWHERE:
        if u in text:
            found.add(u)
    for u in UNITS_AFTER_NUMBER:
        # (number or %N) + optional space + the symbol, not glued to a word
        if re.search(r"(?:%\d|\d)\s*" + re.escape(u) + r"(?![^\W\d_])", text):
            found.add(u)
    return found


def check_file(path: Path, errors: list, warnings: list) -> int:
    rel = path.relative_to(ROOT)
    entries, header = parse_po(path)

    nplurals = None
    pf = header.get("Plural-Forms", "")
    m = re.search(r"nplurals\s*=\s*(\d+)", pf)
    if m:
        nplurals = int(m.group(1))

    translated = same = 0
    for e in entries:
        src = e.get("msgid", "")
        plural_src = e.get("msgid_plural")
        forms = ([e[k] for k in sorted(e) if k.startswith("msgstr[")]
                 if plural_src is not None else
                 ([e["msgstr"]] if e.get("msgstr") else []))
        forms = [f for f in forms if f]
        if not forms:
            continue
        translated += 1
        if all(f in (src, plural_src) for f in forms):
            same += 1

        want = placeholders(src)
        for f in forms:
            if placeholders(f) != want:
                errors.append(
                    f"{rel}: placeholder mismatch\n"
                    f"      source:      {src!r} -> {want or 'none'}\n"
                    f"      translation: {f!r} -> {placeholders(f) or 'none'}")

        if plural_src is not None and nplurals is not None:
            got = len([k for k in e if k.startswith("msgstr[")])
            if got != nplurals:
                errors.append(
                    f"{rel}: {src!r} has {got} plural form(s) but the header "
                    f"declares nplurals={nplurals}")

        for edge, name in ((src[:1], "leading"), (src[-1:], "trailing")):
            if edge == " ":
                for f in forms:
                    ok = f.startswith(" ") if name == "leading" else f.endswith(" ")
                    if not ok:
                        errors.append(
                            f"{rel}: {name} space dropped from {src!r}\n"
                            f"      -> {f!r}\n"
                            f"      This fragment is concatenated with a "
                            f"measurement; without the space the words run "
                            f"together.")

        src_units = units_in(src)
        for f in forms:
            missing = src_units - units_in(f)
            if missing:
                errors.append(
                    f"{rel}: unit symbol {sorted(missing)} lost from {src!r}\n"
                    f"      -> {f!r}\n"
                    f"      SI symbols are identical in every language and "
                    f"must be copied verbatim.")

        for f in forms:
            if len(f) > LENGTH_WARN_MIN and len(f) > LENGTH_WARN_RATIO * len(src):
                warnings.append(
                    f"{rel}: {len(f)/max(len(src),1):.1f}x longer than source "
                    f"— may truncate on a small screen\n"
                    f"      {src!r}\n      -> {f!r}")

    if translated and same / translated >= SOURCE_EQUAL_WARN:
        warnings.append(
            f"{rel}: {same}/{translated} entries are identical to the English "
            f"source.\n      That is the signature of Crowdin's 'Skip "
            f"untranslated strings' export\n      setting being OFF "
            f"(Project Settings -> Export), which pads untranslated\n"
            f"      strings with source text and makes a partial language look "
            f"complete.")

    if shutil.which("msgfmt"):
        r = subprocess.run(["msgfmt", "-c", "-o", "/dev/null", str(path)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            errors.append(f"{rel}: msgfmt -c failed\n" +
                          "\n".join("      " + l
                                    for l in r.stderr.strip().splitlines()[:8]))
    return translated


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    warn_fatal = "--warnings-fail" in sys.argv

    langs = args or sorted(d.name for d in L10N.iterdir()
                           if d.is_dir() and d.name != "templates")
    files = [p for lang in langs
             for p in sorted((L10N / lang).glob("*.po"))]
    if not files:
        print("No .po files yet — nothing to check. (Translations arrive via "
              "Crowdin;\nsee plugin/l10n/README.md.)")
        return 0

    errors: list[str] = []
    warnings: list[str] = []
    total = 0
    for f in files:
        total += check_file(f, errors, warnings)

    print(f"{len(files)} file(s), {total} translated entries")
    for w in warnings:
        print(f"\nWARN  {w}")
    for e in errors:
        print(f"\nFAIL  {e}", file=sys.stderr)

    print()
    if errors:
        print(f"{len(errors)} error(s), {len(warnings)} warning(s)", file=sys.stderr)
        return 1
    if warnings and warn_fatal:
        print(f"0 errors, {len(warnings)} warning(s) — failing on --warnings-fail")
        return 1
    print(f"PASS — 0 errors, {len(warnings)} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
