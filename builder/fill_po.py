#!/usr/bin/env python3
"""Fill a language's labels.po and help.po from AI-provided translations.

This is a maintainer helper for the initial machine-translation seed. Crowdin
owns the .po after the project connects; do not run this to overwrite work that
came back from Crowdin.

Usage:
    python3 builder/fill_po.py <lang> <translations.json>

<lang> is a KOReader locale directory name (see plugin/l10n/LOCALES), e.g. de,
pt_BR, zh_CN. <translations.json> maps source msgid -> translated string, for
strings from EITHER component; entries whose msgid is not in a component are
ignored for that component, and a msgid left out (or mapped to "") stays
untranslated and falls back to English at runtime.

Writes plugin/l10n/<lang>/labels.po and plugin/l10n/<lang>/help.po by copying
each component template and setting msgstr. Never touches the .pot templates.
"""
import json
import sys
from pathlib import Path

import polib

ROOT = Path(__file__).resolve().parent.parent
TPL = ROOT / "plugin/l10n/templates"
COMPONENTS = ("labels", "help")

# Minimal, safe default. No string here uses ngettext, so the plural expression
# is cosmetic; a translator/Crowdin sets the real one per language later.
PLURAL_FORMS = "nplurals=2; plural=(n != 1);"


def fill(lang: str, translations: dict) -> None:
    out_dir = ROOT / "plugin/l10n" / lang
    out_dir.mkdir(parents=True, exist_ok=True)
    for component in COMPONENTS:
        tpl = TPL / f"glimpse-{component}.pot"
        po = polib.pofile(str(tpl))
        po.metadata["Language"] = lang
        po.metadata["Plural-Forms"] = PLURAL_FORMS
        # fill the placeholder headers so msgfmt does not warn on every build;
        # Crowdin overwrites these once it owns the file
        po.metadata["Last-Translator"] = "AI seed <noreply@glimpse>"
        po.metadata["Language-Team"] = lang
        po.metadata["PO-Revision-Date"] = "2026-08-25 00:00+0000"
        n = 0
        for entry in po:
            msg = translations.get(entry.msgid)
            if msg:
                entry.msgstr = msg
                # a filled entry is no longer fuzzy/untranslated
                if "fuzzy" in entry.flags:
                    entry.flags.remove("fuzzy")
                n += 1
        po.save(str(out_dir / f"{component}.po"))
        total = len([e for e in po if e.msgid])
        print(f"  {lang}/{component}.po: {n}/{total} translated")


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    lang = sys.argv[1]
    data = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    fill(lang, data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
