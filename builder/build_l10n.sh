#!/usr/bin/env bash
#
# Glimpse translations: regenerate the .pot templates from plugin/main.lua,
# and compile each language's .po files into the single .mo the plugin loads
# at runtime. Run this:
#   - during dev (via builder/check.sh) to keep templates in sync and catch
#     broken .po syntax early
#   - before every release (via release.sh) so shipped .mo files are always
#     freshly compiled from current .po source, never stale
#
# Two translation files, one .mo:
#   templates/glimpse-labels.pot -> <lang>/labels.po  (required set)
#   templates/glimpse-help.pot   -> <lang>/help.po    (optional explainers)
# Both are merged with msgcat and compiled to <lang>/glimpse.mo, because
# gettext looks up one catalogue per language. Splitting only affects what
# translators are ASKED to do — see plugin/l10n/README.md for why.
#
# Needs xgettext, msgmerge, msgcat, msgfmt (GNU gettext-tools — `brew install
# gettext` on macOS) and python3.
#
# Usage:  ./builder/build_l10n.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L10N="$ROOT/plugin/l10n"
POT="$L10N/templates/glimpse.pot"

if ! command -v xgettext >/dev/null 2>&1; then
    echo "xgettext not found — install GNU gettext-tools (e.g. 'brew install gettext')." >&2
    exit 1
fi

mkdir -p "$L10N/templates"

echo "== Extracting translatable strings =="
# Run from plugin/ so any path xgettext writes is relative to the plugin rather
# than machine-specific.
#
# LOCATIONS ARE KEPT HERE AND STRIPPED IN split_pot.py — deliberately.
# xgettext stamps "#: main.lua:1642" beside every string, and those line numbers
# shift whenever main.lua grows, which is every scanner release. That fed a loop
# with no exit: the .pot changed, got committed, Crowdin saw a modified source
# file, re-synced, regenerated all 58 languages and opened a pull request
# containing ZERO new translation work; meanwhile msgmerge below rewrote all
# 116 .po the same way. v1.8.2 added 469 lines to main.lua and churned 119 files
# on that basis alone. Measured: inserting 40 blank lines and changing no string
# at all altered 343 lines of the template.
# The obvious fix — --no-location right here — BREAKS split_pot.py, which routes
# a string to the help component by testing whether its source references all
# sit on `help_text =` lines. Without locations everything lands in labels
# (169/0 instead of 141/28). So this master template keeps its locations, is
# read only by split_pot.py, and is not a file Crowdin ever sees; the two
# COMPONENT templates it writes are the Crowdin sources (see crowdin.yml), and
# those are stripped there. msgmerge below then drops them from the .po too.
# Nothing of value is lost: every string lives in main.lua, so the line number
# was the only information "#:" carried, and Crowdin shows translators the
# "#. TRANSLATORS:" comments instead — all 358 of those survive.
#
# --add-comments=TRANSLATORS:  (NOT bare --add-comments)
# Bare --add-comments extracts EVERY comment preceding a string, and main.lua's
# comments are implementation notes — the LuaJIT 200-local ceiling, how loadMO
# merges catalogues, crengine tokenization. That shipped 2430 lines of it into
# the .pot as translator "context", burying anything useful. With the tag, only
# comments deliberately written as
#     -- TRANSLATORS: <note>
# are extracted, so the context field carries signal instead of noise.
# Extract to a temp file first: the .pot is COMMITTED (Crowdin reads it to seed
# new languages), and xgettext stamps a fresh POT-Creation-Date on every run, so
# writing it unconditionally would dirty the tree on every check.sh even when no
# source string changed. Keep the existing file when only that header differs.
POT_TMP="$(mktemp)"
trap 'rm -f "$POT_TMP" "$POT_TMP.a" "$POT_TMP.b"' EXIT
( cd "$ROOT/plugin" && xgettext --language=Lua --from-code=UTF-8 \
    --keyword=_ --keyword=_.ngettext:1,2 \
    --package-name="Glimpse" \
    --copyright-holder="Erik Fanki" \
    --add-comments=TRANSLATORS: \
    -o "$POT_TMP" \
    main.lua )
if [ -f "$POT" ] \
   && grep -v '^"POT-Creation-Date:' "$POT"     > "$POT_TMP.a" \
   && grep -v '^"POT-Creation-Date:' "$POT_TMP" > "$POT_TMP.b" \
   && cmp -s "$POT_TMP.a" "$POT_TMP.b"; then
    echo "  (source strings unchanged — keeping the existing template)"
else
    mv "$POT_TMP" "$POT"
fi
echo "  $(grep -c '^msgid "' "$POT") strings total"

echo "== Splitting into translation components =="
python3 "$ROOT/builder/split_pot.py"

# Reject unknown locale directories BEFORE compiling anything.
#
# The runtime loads l10n/<KOReader's current_lang>/glimpse.mo. A directory
# whose name isn't one of KOReader's codes produces a .mo that is built,
# shipped, and never loaded — silently, with no error and an untranslated UI.
# Whichever translation platform writes these directories has to be told the
# mapping explicitly (its default "locale with underscore" yields de_DE where
# KOReader wants de), so this checks the result instead of trusting the config.
LOCALES_FILE="$L10N/LOCALES"
bad=0
for langdir in "$L10N"/*/; do
    lang="$(basename "$langdir")"
    [ "$lang" = "templates" ] && continue
    if ! grep -qx "$lang" "$LOCALES_FILE" 2>/dev/null; then
        echo "ERROR: l10n/$lang/ is not a locale KOReader uses." >&2
        echo "       A .mo built there would never be loaded at runtime." >&2
        echo "       Fix the platform's language mapping, or add the code to" >&2
        echo "       plugin/l10n/LOCALES if KOReader really does ship it." >&2
        bad=1
    fi
done
[ "$bad" -eq 0 ] || exit 1

shopt -s nullglob
found=0
for langdir in "$L10N"/*/; do
    lang="$(basename "$langdir")"
    [ "$lang" = "templates" ] && continue
    pos=()
    for component in labels help; do
        po="$langdir$component.po"
        [ -f "$po" ] || continue
        # Bring each .po up to date against its template (new/changed/removed
        # msgids) before compiling, so a translator's file never silently
        # falls behind the source strings.
        # --no-location: the template has no "#:" references any more (stripped
        # in split_pot.py — see the note above), but msgmerge KEEPS the ones
        # already sitting in an existing .po unless told otherwise, so without
        # this the 116 translated files would carry stale line numbers forever
        # and the churn this whole change exists to stop would continue there.
        msgmerge --quiet --update --backup=off --no-location "$po" \
            "$L10N/templates/glimpse-$component.pot"
        pos+=("$po")
    done
    [ ${#pos[@]} -gt 0 ] || continue
    found=1
    echo "== $lang =="
    # One catalogue per language: labels + whatever help text exists.
    # --use-first keeps the labels entry if a msgid somehow appears in both.
    msgcat --use-first "${pos[@]}" -o "$langdir.combined.po"
    msgfmt -c -o "$langdir/glimpse.mo" "$langdir.combined.po"
    rm -f "$langdir.combined.po"
    echo "  ${#pos[@]} component(s) -> $lang/glimpse.mo"
done

if [ "$found" -eq 0 ]; then
    echo "== No plugin/l10n/<lang>/{labels,help}.po yet — nothing to compile. =="
    echo "   (expected until the Crowdin project has translations — see plugin/l10n/README.md)"
fi
