#!/usr/bin/env bash
# Builds Shade.app (menu-bar only) into ./build. Ad-hoc signed for local use; release.sh sets:
#   VERSION=1.2.3       version shown in Finder and the About window (default 0.1.0)
#   UNIVERSAL=1         build for Apple silicon and Intel
#   SIGN_IDENTITY=...   "Developer ID Application: ..." certificate: signs with the hardened runtime
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_FLAGS=(-c release)
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_FLAGS[@]}"
BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/Shade"
APP="build/Shade.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Shade"

# highlight.js, its built-in themes and the theme catalog, read by SyntaxHighlighting.swift.
mkdir -p "$APP/Contents/Resources"
cp -R Resources/Highlighting "$APP/Contents/Resources/"
# marked, which renders the Markdown preview (MarkdownPreview.swift).
cp -R Resources/Markdown "$APP/Contents/Resources/"
# App icon, drawn by scripts/make_icon.py.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Shade</string>
    <key>CFBundleIdentifier</key><string>io.github.dineshvg.shade</string>
    <key>CFBundleExecutable</key><string>Shade</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>NSAppleEventsUsageDescription</key><string>Programs you run in Shade's terminal cards asked to control another app.</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Dinesh Gangatharan. MIT License.</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --entitlements scripts/Shade.entitlements \
        --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP ($VERSION)"
