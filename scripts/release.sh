#!/usr/bin/env bash
# Builds a signed, notarized build/Shade-<version>.dmg for GitHub Releases.
#
# One-time setup (needs an Apple Developer Program membership):
#   1. Create a "Developer ID Application" certificate (Xcode › Settings › Accounts › Manage Certificates)
#   2. Store notarization credentials in the keychain:
#        xcrun notarytool store-credentials shade-notary --apple-id <apple-id> --team-id <TEAMID>
#      (use an app-specific password from account.apple.com)
#
# Usage:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/release.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: ./scripts/release.sh <version>, for example 1.0.0}"
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your \"Developer ID Application: ...\" certificate name}"
NOTARY_PROFILE="${NOTARY_PROFILE:-shade-notary}"
APP="build/Shade.app"
DMG="build/Shade-$VERSION.dmg"

# notarytool exits successfully even when Apple rejects the upload, so check its verdict.
notarize() {
    local log="build/notary-$(basename "$1").log"
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$log"
    if ! grep -q "status: Accepted" "$log"; then
        echo "Notarization of $1 failed. Details: xcrun notarytool log <submission id> --keychain-profile $NOTARY_PROFILE"
        exit 1
    fi
}

VERSION="$VERSION" UNIVERSAL=1 SIGN_IDENTITY="$SIGN_IDENTITY" ./scripts/bundle.sh
codesign --verify --deep --strict --verbose=2 "$APP"

# Notarize the app and staple the ticket, so it also opens without a network connection.
ZIP="build/Shade-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"
rm "$ZIP"

# Disk image with the app and a shortcut to Applications, signed and notarized too.
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Shade $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo "Built $DMG"
echo "Publish it with:  gh release create v$VERSION \"$DMG\" --title \"Shade $VERSION\" --generate-notes"
