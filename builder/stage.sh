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
cp "$ROOT"/plugin/_meta.lua "$ROOT"/plugin/main.lua "$ROOT"/plugin/glimpse_scanner.lua \
   "$ROOT"/LICENSE "$DIST/glimpse.koplugin/"
cp -r "$ROOT"/plugin/assets "$DIST/glimpse.koplugin/"

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
