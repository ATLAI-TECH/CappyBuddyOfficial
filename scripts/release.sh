#!/usr/bin/env bash
# Build, sign, notarize, staple, zip CapyBuddy, then publish a Sparkle update
# via GitHub Releases (binary) + GitHub Pages (appcast.xml).
#
# Distribution model (open source):
#   * The .zip ships as a GitHub Release asset:
#       https://github.com/ATLAI-TECH/CapyBuddy/releases/download/vX.Y.Z/CapyBuddy-X.Y.Z.zip
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

RELEASES_DIR="releases"          # gitignored staging area for signed zips
DOCS_DIR="docs"                  # GitHub Pages source — appcast.xml lives here
APPCAST_PATH="$DOCS_DIR/appcast.xml"

REPO_SLUG="ATLAI-TECH/CapyBuddy"
RELEASES_URL="https://github.com/$REPO_SLUG/releases"

SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
TAG="v${SHORT_VERSION}"
ZIP_NAME="CapyBuddy-${SHORT_VERSION}.zip"
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

# --- Pre-flight: guard against a forgotten CFBundleVersion bump ---------------
# Sparkle compares CFBundleVersion (build number), not the marketing string.
# If this build number already appears in the published appcast, clients won't
# see an update — fail loudly instead of shipping a no-op release.
if [ -f "$APPCAST_PATH" ] && grep -q "sparkle:version=\"${BUILD_VERSION}\"" "$APPCAST_PATH"; then
    echo "ERROR: CFBundleVersion=$BUILD_VERSION is already in $APPCAST_PATH." >&2
    echo "       Bump CFBundleVersion in $INFO_PLIST before releasing." >&2
    exit 1
fi

# Clear the staging dir so it holds ONLY this version's zip. generate_appcast
# applies --download-url-prefix (tag-specific) to every archive it finds, so a
# stale zip from a previous version would be handed this tag's URL. Older
# versions are preserved from the existing docs/appcast.xml instead — Sparkle
# keeps appcast entries whose archives are no longer in the directory.
rm -rf "$BUILD_DIR" "$RELEASES_DIR"
mkdir -p "$BUILD_DIR" "$RELEASES_DIR" "$DOCS_DIR"

echo "==> [1/7] Archiving (scheme: $SCHEME, version: $SHORT_VERSION build $BUILD_VERSION)"
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

echo "==> [2/7] Exporting Developer ID-signed .app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR"

APP_PATH="$EXPORT_DIR/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
    echo "Export did not produce $APP_PATH" >&2
    exit 1
fi

echo "==> [3/7] Submitting to Apple notary service"
ZIP_FOR_NOTARY="$BUILD_DIR/notary-submission.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_FOR_NOTARY"
xcrun notarytool submit "$ZIP_FOR_NOTARY" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> [4/7] Stapling notary ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> [5/7] Packaging $ZIP_NAME into $RELEASES_DIR/"
DIST_ZIP="$RELEASES_DIR/$ZIP_NAME"
# Sparkle expects a flat zip of the .app at the root, which `ditto -c -k
# --keepParent` produces.
ditto -c -k --keepParent "$APP_PATH" "$DIST_ZIP"

echo "==> [6/7] Generating signed $APPCAST_PATH"
# generate_appcast signs each zip in RELEASES_DIR with the keychain private key
# and rewrites the enclosure URLs to point at the GitHub Release download path
# for this tag. Older entries already in the appcast are preserved so users a
# version or two behind can still upgrade.
"$GENERATE_APPCAST" \
    --link "$RELEASES_URL" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    -o "$APPCAST_PATH" \
    "$RELEASES_DIR"

echo "==> [7/7] Publishing GitHub Release $TAG"
if command -v gh >/dev/null 2>&1; then
    if gh release view "$TAG" >/dev/null 2>&1; then
        gh release upload "$TAG" "$DIST_ZIP" --clobber
    else
        gh release create "$TAG" "$DIST_ZIP" \
            --title "CapyBuddy $SHORT_VERSION" \
            --notes "Automated release. See appcast for details."
    fi
    echo "    Uploaded $ZIP_NAME to $RELEASES_URL/tag/$TAG"
else
    echo "    gh CLI not found — upload manually:"
    echo "      1. Create a release tagged '$TAG' at $RELEASES_URL/new"
    echo "      2. Attach: $DIST_ZIP"
fi

echo ""
echo "Done."
echo "  Notarized + stapled app: $APP_PATH"
echo "  Distribution zip:        $DIST_ZIP  (-> Release asset $TAG)"
echo "  Appcast:                 $APPCAST_PATH  (-> GitHub Pages)"
echo ""
echo "Next:"
echo "  git add $APPCAST_PATH && git commit -m \"release: CapyBuddy $SHORT_VERSION\" && git push"
echo "  (GitHub Pages then serves the updated feed; existing installs get the update.)"
