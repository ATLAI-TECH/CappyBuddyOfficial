#!/usr/bin/env bash
# Build, sign, notarize, staple, and package CapyBuddy as a DMG, then publish a
# Sparkle update via GitHub Releases (binary) + GitHub Pages (appcast.xml).
#
# Why a DMG and not a zip: a zip round-trips the .app through whatever extractor
# the user happens to use, and several of them (including Finder's Archive
# Utility in some cases) flatten the symlinks inside Sparkle.framework. That
# breaks the code-signature seal — Gatekeeper then rejects the app with
# "unsealed contents present in the root directory of an embedded framework" /
# "Apple could not verify ... is free of malware". A DMG is a read-only image
# that preserves the bundle byte-for-byte, so drag-installing it can't corrupt
# the framework. (Sparkle handles .dmg enclosures natively.)
#
# Distribution model (open source):
#   * The .dmg ships as a GitHub Release asset:
#       https://github.com/ATLAI-TECH/CapyBuddy/releases/download/vX.Y.Z/CapyBuddy-X.Y.Z.dmg
#   * appcast.xml is written to docs/ and served via GitHub Pages:
#       https://atlai-tech.github.io/CapyBuddy/appcast.xml
#     (matches SUFeedURL in CapyBuddyPro-Info.plist)
#
# Prereqs (one-time):
#   1. Developer ID Application certificate installed in login keychain.
#   2. App-specific password stored under notarytool profile "CAPYBUDDY_NOTARY":
#        xcrun notarytool store-credentials CAPYBUDDY_NOTARY \
#          --apple-id "you@example.com" --team-id 9A6Q68R555 \
#          --password "xxxx-xxxx-xxxx-xxxx"
#   3. Sparkle EdDSA private key in the keychain (public key already pasted into
#      CapyBuddyPro-Info.plist under SUPublicEDKey). Verify the pair with:
#        generate_keys -p   # must print the SUPublicEDKey value
#   4. GitHub Pages enabled for this repo: Settings -> Pages -> Source =
#      "Deploy from a branch", branch = main, folder = /docs.
#   5. (Optional) GitHub CLI `gh` authenticated, for automatic asset upload.
#      Without it, the script prints manual upload instructions and still
#      produces a ready-to-commit appcast.xml.
#
# The Sparkle helper binaries (generate_appcast / sign_update) are resolved
# automatically from Xcode's DerivedData SourcePackages — no fragile ./bin
# symlinks to maintain. Override with SPARKLE_BIN=/path/to/Sparkle/bin if needed.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

SCHEME="CapyBuddy"
PROJECT="CapyBuddy.xcodeproj"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/CapyBuddy.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="scripts/ExportOptions.plist"
NOTARY_PROFILE="CAPYBUDDY_NOTARY"
APP_NAME="CapyBuddy.app"
INFO_PLIST="CapyBuddy/App/CapyBuddyPro-Info.plist"

# Developer ID Application identity used to sign the DMG itself. The .app is
# already signed by the export step; the disk image needs its own signature
# before it can be notarized. Override with SIGN_IDENTITY=... if the cert name
# ever changes.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: ATLAI TECHNOLOGY LTD (9A6Q68R555)}"
VOL_NAME="CapyBuddy"             # mounted volume name for the DMG
DMG_BACKGROUND="scripts/dmg-assets/dmg-background.tiff"   # HiDPI tiff, see make-background.swift

RELEASES_DIR="releases"          # gitignored staging area for signed disk images
DOCS_DIR="docs"                  # GitHub Pages source — appcast.xml lives here
APPCAST_PATH="$DOCS_DIR/appcast.xml"

REPO_SLUG="ATLAI-TECH/CapyBuddy"
RELEASES_URL="https://github.com/$REPO_SLUG/releases"

SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
TAG="v${SHORT_VERSION}"
DMG_NAME="CapyBuddy-${SHORT_VERSION}.dmg"
DOWNLOAD_PREFIX="https://github.com/$REPO_SLUG/releases/download/$TAG/"

# --- Resolve Sparkle helper binaries -----------------------------------------
if [ -n "${SPARKLE_BIN:-}" ]; then
    GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
else
    GENERATE_APPCAST=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -path "*sparkle*/bin/generate_appcast" -type f 2>/dev/null | head -1 || true)
fi
if [ -z "${GENERATE_APPCAST:-}" ] || [ ! -x "$GENERATE_APPCAST" ]; then
    echo "ERROR: generate_appcast not found. Build the app once in Xcode to" >&2
    echo "       resolve the Sparkle package, or set SPARKLE_BIN=/path/to/bin." >&2
    exit 1
fi
echo "==> Using Sparkle tools at: $(dirname "$GENERATE_APPCAST")"

# --- Pre-flight: create-dmg (builds the drag-to-Applications disk image) ------
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "ERROR: create-dmg not found. Install it with: brew install create-dmg" >&2
    echo "       (it lays out the window background + Applications drop link)." >&2
    exit 1
fi
if [ ! -f "$DMG_BACKGROUND" ]; then
    echo "ERROR: DMG background missing: $DMG_BACKGROUND" >&2
    echo "       Regenerate it: swift scripts/dmg-assets/make-background.swift" >&2
    exit 1
fi

# --- Pre-flight: guard against a forgotten CFBundleVersion bump ---------------
# Sparkle compares CFBundleVersion (build number), not the marketing string.
# If this build number already appears in the published appcast, clients won't
# see an update — fail loudly instead of shipping a no-op release.
if [ -f "$APPCAST_PATH" ] && grep -q "sparkle:version=\"${BUILD_VERSION}\"" "$APPCAST_PATH"; then
    echo "ERROR: CFBundleVersion=$BUILD_VERSION is already in $APPCAST_PATH." >&2
    echo "       Bump CFBundleVersion in $INFO_PLIST before releasing." >&2
    exit 1
fi

# Clear the staging dir so it holds ONLY this version's disk image.
# generate_appcast applies --download-url-prefix (tag-specific) to every archive
# it finds, so a stale image from a previous version would be handed this tag's
# URL. Older versions are preserved from the existing docs/appcast.xml instead —
# Sparkle keeps appcast entries whose archives are no longer in the directory.
rm -rf "$BUILD_DIR" "$RELEASES_DIR"
mkdir -p "$BUILD_DIR" "$RELEASES_DIR" "$DOCS_DIR"

echo "==> [1/8] Archiving (scheme: $SCHEME, version: $SHORT_VERSION build $BUILD_VERSION)"
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    "CODE_SIGN_IDENTITY=Apple Development" \
    archive
# The project's Release config pins CODE_SIGN_IDENTITY to "Developer ID
# Application" while keeping CODE_SIGN_STYLE=Automatic, which Xcode rejects as a
# conflict at archive time. We archive with the Apple Development identity (what
# automatic signing expects) and let the developer-id export step below re-sign
# the .app with the Developer ID certificate.

echo "==> [2/8] Exporting Developer ID-signed .app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR"

APP_PATH="$EXPORT_DIR/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
    echo "Export did not produce $APP_PATH" >&2
    exit 1
fi

echo "==> [3/8] Submitting .app to Apple notary service"
# Notarize (and below, staple) the .app itself so the bundle carries its own
# ticket — that way the installed app passes Gatekeeper even offline, regardless
# of how it got onto disk. The DMG is notarized separately in step [6/8].
ZIP_FOR_NOTARY="$BUILD_DIR/notary-submission.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_FOR_NOTARY"
xcrun notarytool submit "$ZIP_FOR_NOTARY" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> [4/8] Stapling notary ticket to .app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> [5/8] Building and signing $DMG_NAME (drag-to-Applications layout)"
# A DMG preserves the .app byte-for-byte (symlinks inside Sparkle.framework
# included), so drag-installing it can't break the code-signature seal the way a
# re-extracted zip can. create-dmg lays out a branded window: the app icon on
# the left, an Applications drop-link on the right, and a background image with
# an arrow telling the user to drag one onto the other. It also signs the image.
#
# Note: create-dmg drives Finder via AppleScript to set the window background and
# icon positions, so it needs a logged-in GUI session. The FIRST run may trigger
# a one-time macOS automation prompt ("Terminal wants to control Finder") — allow
# it. The --icon / --app-drop-link coordinates must match make-background.swift.
DIST_DMG="$RELEASES_DIR/$DMG_NAME"
DMG_STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP_PATH" "$DMG_STAGE/$APP_NAME"   # only the app; create-dmg adds the Applications link
create-dmg \
    --volname "$VOL_NAME" \
    --background "$DMG_BACKGROUND" \
    --window-pos 200 120 \
    --window-size 640 400 \
    --icon-size 110 \
    --icon "$APP_NAME" 170 200 \
    --app-drop-link 470 200 \
    --no-internet-enable \
    --hdiutil-quiet \
    --codesign "$SIGN_IDENTITY" \
    "$DIST_DMG" \
    "$DMG_STAGE"

echo "==> [6/8] Notarizing + stapling $DMG_NAME"
xcrun notarytool submit "$DIST_DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$DIST_DMG"
xcrun stapler validate "$DIST_DMG"
spctl -a -t open --context context:primary-signature -vvv "$DIST_DMG" 2>&1 || true

echo "==> [7/8] Generating signed $APPCAST_PATH"
# generate_appcast signs each archive in RELEASES_DIR (it handles .dmg natively)
# with the keychain private key and rewrites enclosure URLs to point at the
# GitHub Release download path for this tag. Older entries already in the
# appcast are preserved so users a version or two behind can still upgrade.
"$GENERATE_APPCAST" \
    --link "$RELEASES_URL" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    -o "$APPCAST_PATH" \
    "$RELEASES_DIR"

echo "==> [8/8] Publishing GitHub Release $TAG"
# A second, version-less copy named CapyBuddy.dmg is also uploaded so the
# landing page can link to a stable "latest" URL that never changes between
# releases:
#   https://github.com/ATLAI-TECH/CapyBuddy/releases/latest/download/CapyBuddy.dmg
STABLE_DMG="$BUILD_DIR/CapyBuddy.dmg"
cp -f "$DIST_DMG" "$STABLE_DMG"
if command -v gh >/dev/null 2>&1; then
    if gh release view "$TAG" >/dev/null 2>&1; then
        gh release upload "$TAG" "$DIST_DMG" "$STABLE_DMG" --clobber
    else
        gh release create "$TAG" "$DIST_DMG" "$STABLE_DMG" \
            --title "CapyBuddy $SHORT_VERSION" \
            --notes "Automated release. See appcast for details."
    fi
    echo "    Uploaded $DMG_NAME (+ stable CapyBuddy.dmg) to $RELEASES_URL/tag/$TAG"
else
    echo "    gh CLI not found — upload manually:"
    echo "      1. Create a release tagged '$TAG' at $RELEASES_URL/new"
    echo "      2. Attach: $DIST_DMG"
fi

echo ""
echo "Done."
echo "  Notarized + stapled app: $APP_PATH"
echo "  Distribution DMG:        $DIST_DMG  (-> Release asset $TAG)"
echo "  Appcast:                 $APPCAST_PATH  (-> GitHub Pages)"
echo ""
echo "Next:"
echo "  git add $APPCAST_PATH && git commit -m \"release: CapyBuddy $SHORT_VERSION\" && git push"
echo "  (GitHub Pages then serves the updated feed; existing installs get the update.)"
