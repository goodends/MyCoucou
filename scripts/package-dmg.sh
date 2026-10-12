#!/usr/bin/env bash
# Builds MyCoucou for macOS and wraps it in a drag-to-install DMG.
#
#   ./scripts/package-dmg.sh            version is read from the built Info.plist
#   ./scripts/package-dmg.sh 1.0.0      and checked against this argument
#
# This signs ad-hoc, so Gatekeeper still asks the user to confirm the first
# launch. It does not notarize and it does not publish: see release.sh for that.
set -euo pipefail

WANTED_VERSION="${1:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/mycoucou-dmg"
STAGE_DIR="$BUILD_DIR/stage"
DMG_DIR="$REPO_ROOT/dist"

die() { echo "error: $*" >&2; exit 1; }

command -v create-dmg >/dev/null || die "create-dmg is not installed (brew install create-dmg)"
cd "$REPO_ROOT/NotchBuddy"
xcodegen generate >/dev/null

PLIST=Resources/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
[ -n "$WANTED_VERSION" ] && [ "$WANTED_VERSION" != "$VERSION" ] \
  && die "project.yml says $VERSION, not $WANTED_VERSION: update CFBundleShortVersionString in NotchBuddy/project.yml"

# ad-hoc: no Developer ID certificate is required. OTHER_CODE_SIGN_FLAGS is
# cleared because the --timestamp the Release config asks for needs one.
rm -rf "$BUILD_DIR" && mkdir -p "$STAGE_DIR"
xcodebuild \
  -project NotchBuddy.xcodeproj \
  -scheme NotchBuddy \
  -configuration Release \
  build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  OTHER_CODE_SIGN_FLAGS="" \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" >/dev/null

APP="$BUILD_DIR/MyCoucou.app"
[ -d "$APP" ] || die "the build produced no $APP"
codesign --verify --strict "$APP" || die "the ad-hoc signature does not verify"

mkdir -p "$DMG_DIR"
rm -rf "$STAGE_DIR"/* && cp -R "$APP" "$STAGE_DIR/"
DMG="$DMG_DIR/MyCoucou-$VERSION.dmg"
rm -f "$DMG"
create-dmg \
  --volname "MyCoucou $VERSION" \
  --window-size 500 340 \
  --icon-size 110 \
  --icon "MyCoucou.app" 160 170 \
  --app-drop-link 340 170 \
  --no-internet-enable \
  "$DMG" "$STAGE_DIR" >/dev/null

hdiutil verify "$DMG" >/dev/null || die "the DMG does not verify"
echo "DMG ready: $DMG"