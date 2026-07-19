#!/usr/bin/env bash
#
# Build glimpse.koplugin.zip and publish a GitHub release whose attached zip
# is exactly what the in-plugin updater downloads and installs.
#
# While the plugin is in testing, releases are marked PRE-RELEASE by default:
# the GitHub "latest release" API never returns those, so only devices with
# "Include pre-release versions" enabled (yours) will be offered them. Pass
# --final for a proper public release.
#
# Usage:
#   ./release.sh                 # pre-release the version in plugin/_meta.lua
#   ./release.sh 0.2.0           # bump _meta.lua to 0.2.0, then pre-release
#   ./release.sh 0.2.0 --notes "Gallery + captions"
#   ./release.sh 1.0.0 --final   # a real (non-pre) release
#   DRYRUN=1 ./release.sh        # build the zip only, no GitHub calls
#
# Prerequisites:
#   - gh (GitHub CLI) authenticated:  gh auth login
#   - the repo (below) exists on GitHub with at least one pushed commit
#     (a release tag needs a commit to anchor to)
#
set -euo pipefail

REPO="Fank1/glimpse"
ROOT="$(cd "$(dirname "$0")" && pwd)"
META="$ROOT/plugin/_meta.lua"
KOPLUGIN="glimpse.koplugin"           # folder name inside the zip

NOTES=""
VERSION_ARG=""
PRERELEASE_FLAG="--prerelease"
while [ $# -gt 0 ]; do
    case "$1" in
        --notes) NOTES="$2"; shift 2 ;;
        --final) PRERELEASE_FLAG=""; shift ;;
        *)       VERSION_ARG="$1"; shift ;;
    esac
done

# 1. Optional version bump in _meta.lua.
if [ -n "$VERSION_ARG" ]; then
    echo "Bumping version → $VERSION_ARG"
    perl -0pi -e "s/(version\s*=\s*\")[^\"]*(\")/\${1}${VERSION_ARG}\${2}/" "$META"
fi

# 2. Read the version that will be released. (Parsed textually: _meta.lua
# requires KOReader's gettext module, so it can't be dofile'd by plain lua.)
VERSION="$(sed -n 's/.*version *= *"\([^"]*\)".*/\1/p' "$META" | head -1)"
[ -n "$VERSION" ] || { echo "ERROR: could not read version from $META" >&2; exit 1; }
TAG="v$VERSION"
echo "Preparing release $TAG"

# 3. Full check + stage (builds dist/glimpse.koplugin), then the versioned zip.
"$ROOT/builder/stage.sh"
DIST="$ROOT/dist"
ZIP="$DIST/glimpse-$TAG.koplugin.zip"
rm -f "$ZIP"
( cd "$DIST" && zip -rq "$ZIP" "$KOPLUGIN" )
echo "Built $ZIP"

if [ "${DRYRUN:-0}" = "1" ]; then
    echo "DRYRUN=1 — built the zip, skipping GitHub release."
    exit 0
fi

# 4. Preflight: a release tag must anchor to a commit.
DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
if [ -z "$DEFAULT_BRANCH" ]; then
    echo "ERROR: $REPO has no commits yet — push the repo first." >&2
    exit 1
fi

# 4b. Sync the source so the tag reflects this release, not just the zip.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Syncing source to $REPO ($DEFAULT_BRANCH)…"
    git -C "$ROOT" add -A
    if git -C "$ROOT" diff --cached --quiet; then
        echo "Source already up to date — nothing to commit."
    else
        git -C "$ROOT" commit -q \
            -m "Release $TAG" \
            -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
        echo "Committed source for $TAG."
    fi
    git -C "$ROOT" push -q origin "$DEFAULT_BRANCH"
    echo "Pushed source to $DEFAULT_BRANCH."
else
    echo "WARNING: $ROOT is not a git repo — skipping source sync." >&2
fi

# 5. Publish (or update) the release and attach the zip.
[ -n "$NOTES" ] || NOTES="Glimpse $TAG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG exists — replacing its asset."
    gh release upload "$TAG" "$ZIP" --repo "$REPO" --clobber
else
    echo "Creating release $TAG on $REPO${PRERELEASE_FLAG:+ (pre-release)}…"
    gh release create "$TAG" "$ZIP" \
        --repo "$REPO" \
        --target "$DEFAULT_BRANCH" \
        --title "$TAG" \
        --notes "$NOTES" \
        $PRERELEASE_FLAG
fi

echo "Done: $TAG published."
