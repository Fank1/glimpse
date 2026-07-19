#!/bin/sh
# Glimpse triage: analyze_epub.sh <book.epub> [more.epub ...]
# Unzips each book to a temp dir and prints the scanner's verdict for every
# image at every filter level.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)

for epub in "$@"; do
    echo "==== $epub"
    tmp=$(mktemp -d)
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$epub" "$tmp"
    lua "$HERE/analyze_epub.lua" "$tmp" || true
    rm -rf "$tmp"
    echo
done
