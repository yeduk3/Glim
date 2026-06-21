#!/bin/bash
# One-command release: bump version, commit, push, build+sign+notarize, install to
# /Applications, publish the GitHub release, and clean up build artifacts.
#
# Wraps release.sh (which does the build/sign/notarize/staple/zip). This adds the
# surrounding git + install + publish + clean steps so a release is a single command.
#
# Usage:
#   ./ship.sh <version> [-m "commit message"] [-n notes.md] [-y]
#
#   <version>        marketing version, e.g. 1.1.5 (CFBundleShortVersionString)
#   -m "message"     commit subject/body          (default: "release: v<version>")
#   -n notes.md      GitHub release notes file     (default: the commit message)
#   -y               skip the confirmation prompt
#
# Prerequisites (same as release.sh): a "Developer ID Application" certificate in the
# keychain and a notarytool keychain profile (default name: glim-notary). The Team ID is
# read from the certificate automatically; override with GLIM_TEAM_ID.
set -euo pipefail
cd "$(dirname "$0")"

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DD="${GLIM_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/glim-build}"
PROD="$DD/Build/Products"

die() { echo "error: $*" >&2; exit 1; }

# ---- args -------------------------------------------------------------------
VERSION="${1:-}"
[ -n "$VERSION" ] || die "missing <version>. usage: ./ship.sh <version> [-m msg] [-n notes.md] [-y]"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3 (got '$VERSION')"
shift

MSG=""; NOTES_FILE=""; ASSUME_YES=0
while getopts "m:n:y" opt; do
  case "$opt" in
    m) MSG="$OPTARG" ;;
    n) NOTES_FILE="$OPTARG" ;;
    y) ASSUME_YES=1 ;;
    *) die "bad option" ;;
  esac
done
[ -n "$MSG" ] || MSG="release: v$VERSION"
TAG="v$VERSION"
ZIP="/tmp/Glim-$TAG-macos.zip"

# ---- preflight --------------------------------------------------------------
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
command -v gh >/dev/null || die "gh CLI not found"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"

# Team ID from the Developer ID cert (or GLIM_TEAM_ID override).
if [ -z "${GLIM_TEAM_ID:-}" ]; then
  GLIM_TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Developer ID Application' | sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/')"
  [ -n "$GLIM_TEAM_ID" ] || die "no 'Developer ID Application' certificate found and GLIM_TEAM_ID unset"
fi
export GLIM_TEAM_ID

# Don't clobber an existing release/tag.
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
gh release view "$TAG" >/dev/null 2>&1 && die "GitHub release $TAG already exists"

BRANCH="$(git branch --show-current)"
CUR_VERSION="$(grep -m1 'MARKETING_VERSION' project.yml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo '?')"
CUR_BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION' project.yml | grep -oE '[0-9]+' | head -1 || echo 0)"
NEW_BUILD=$((CUR_BUILD + 1))

cat <<PLAN

  Glim ship plan
  -------------
  version     : $CUR_VERSION  ->  $VERSION   (build $CUR_BUILD -> $NEW_BUILD)
  branch      : $BRANCH
  team id     : $GLIM_TEAM_ID
  commit msg  : $(printf '%s' "$MSG" | head -1)
  notes       : ${NOTES_FILE:-<commit message>}
  steps       : bump -> commit+push -> build/notarize -> install /Applications -> gh release $TAG -> clean

PLAN
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "aborted"
fi

# ---- 1. bump version --------------------------------------------------------
echo "==> Bumping project.yml to $VERSION (build $NEW_BUILD)"
sed -i '' -E "s/(MARKETING_VERSION: )\"[^\"]*\"/\1\"$VERSION\"/" project.yml
sed -i '' -E "s/(CURRENT_PROJECT_VERSION: )\"[^\"]*\"/\1\"$NEW_BUILD\"/" project.yml

# ---- 2. commit + push -------------------------------------------------------
echo "==> Committing and pushing"
git add -A
git commit -m "$MSG"
git push origin "$BRANCH"

# ---- 3. build + sign + notarize (writes $ZIP, removes DerivedData Release) ---
echo "==> Building signed + notarized release (this waits on Apple)"
./release.sh "$VERSION"
[ -f "$ZIP" ] || die "release.sh did not produce $ZIP"

# ---- 4. install to /Applications --------------------------------------------
echo "==> Installing to /Applications"
pkill -9 -f "Glim.app/Contents/MacOS/Glim" 2>/dev/null || true
sleep 1
rm -rf /tmp/glim-ship-extract
ditto -xk "$ZIP" /tmp/glim-ship-extract
rm -rf /Applications/Glim.app
mv /tmp/glim-ship-extract/Glim.app /Applications/Glim.app
rm -rf /tmp/glim-ship-extract
"$LSREG" -f /Applications/Glim.app
spctl -a -vvv -t exec /Applications/Glim.app 2>&1 | sed -n '1,3p' || true

# ---- 5. publish GitHub release ----------------------------------------------
echo "==> Creating GitHub release $TAG"
if [ -n "$NOTES_FILE" ]; then
  gh release create "$TAG" "$ZIP" --title "Glim $TAG" --notes-file "$NOTES_FILE"
else
  gh release create "$TAG" "$ZIP" --title "Glim $TAG" --notes "$MSG"
fi

# ---- 6. clean ---------------------------------------------------------------
echo "==> Cleaning build artifacts"
for app in "$PROD"/Debug/Glim.app "$PROD"/Release/Glim.app; do
  [ -d "$app" ] && "$LSREG" -u "$app" 2>/dev/null || true
done
rm -rf "$PROD/Debug" "$PROD/Release"
rm -f "$ZIP"

echo
echo "==> Shipped Glim $TAG"
echo "    installed: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/Glim.app/Contents/Info.plist)"
echo "    release  : $(gh release view "$TAG" --json url --jq .url)"
