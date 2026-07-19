#!/bin/sh
# Glimpse headless checks: syntax gate + fixture regeneration + unit tests.
# Run before calling any change done.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)

echo "== syntax (luac -p) =="
for f in "$HERE"/../plugin/*.lua "$HERE"/scanner_tests.lua; do
    luac -p "$f"
    echo "ok: $f"
done

echo "== fixture =="
python3 "$HERE/make_fixture_epub.py"

echo "== scanner tests =="
lua "$HERE/scanner_tests.lua"

echo "ALL CHECKS PASSED"
