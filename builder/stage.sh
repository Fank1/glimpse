#!/bin/sh
# Stage plugin/ as dist/glimpse.koplugin/ and zip it for installation or a
# GitHub release. The .koplugin folder must sit at the ZIP ROOT with exactly
# that name.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
DIST="$ROOT/dist"

"$HERE/check.sh"

rm -rf "$DIST/glimpse.koplugin"
mkdir -p "$DIST/glimpse.koplugin"
cp "$ROOT"/LICENSE "$DIST/glimpse.koplugin/"
cp -r "$ROOT"/plugin/assets "$DIST/glimpse.koplugin/"

# Stage the Lua sources with their comments removed. Comments are about 39% of
# main.lua, and every user downloads them in the release zip. The stripper
# keeps each file's leading header block and every LINE NUMBER, so a KOReader
# error that says main.lua:5714 still names line 5714 of the source in the
# repository. STRIP=0 stages the sources unchanged.
#
# Each stripped file is then compiled and compared against the original.
# Comments never reach the bytecode and line numbers do, so identical bytecode
# proves the strip changed no token and moved no line. A mismatch stops the
# build rather than shipping a file nobody checked.
echo "== strip comments =="
for f in _meta main glimpse_scanner; do
    src="$ROOT/plugin/$f.lua"
    dst="$DIST/glimpse.koplugin/$f.lua"
    if [ "${STRIP:-1}" = "0" ]; then
        cp "$src" "$dst"
        echo "  $f.lua: copied unchanged (STRIP=0)"
    else
        python3 "$HERE/strip_comments.py" "$src" "$dst"
        python3 "$HERE/strip_comments.py" --check "$src" "$dst" > /dev/null
    fi
done

# Compile translations and stage only the per-language .mo the runtime loads.
# The .po and .pot are build inputs, not shipped. No .po yet == English-only,
# and the loop simply stages nothing.
"$HERE/build_l10n.sh"
for mo in "$ROOT"/plugin/l10n/*/glimpse.mo; do
    [ -f "$mo" ] || continue
    lang=$(basename "$(dirname "$mo")")
    mkdir -p "$DIST/glimpse.koplugin/l10n/$lang"
    cp "$mo" "$DIST/glimpse.koplugin/l10n/$lang/"
done

(cd "$DIST" && rm -f glimpse.zip && zip -qr glimpse.zip glimpse.koplugin)
echo "staged: $DIST/glimpse.koplugin and $DIST/glimpse.zip"
