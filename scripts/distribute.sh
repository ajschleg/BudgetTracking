#!/bin/bash
# Build, notarize, package, and deliver BudgetTracking.app
# Usage: ./scripts/distribute.sh
#
# Uses the Apple ID stored in Xcode's account settings for notarization
# (no separate credential setup needed).

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="BudgetTracking"
APP_NAME="BudgetTracking"
TEAM_ID="98AUV869NF"

ARCHIVE_PATH="/tmp/${APP_NAME}.xcarchive"
EXPORT_OPTIONS="/tmp/${APP_NAME}-ExportOptions.plist"
EXPORT_PATH="${PROJECT_DIR}/Exports/${APP_NAME}"
APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"
DMG_STAGING="/tmp/${APP_NAME}-dmg-staging"
DELIVERY_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/BudgetTracking-Releases"

cleanup() {
    rm -f "$EXPORT_OPTIONS"
    rm -rf "$DMG_STAGING"
}
trap cleanup EXIT

# ── Stage 1: Clean ──────────────────────────────────────────────────────────

echo "=== Stage 1/7: Cleaning build folder..."
xcodebuild -project "$PROJECT_DIR/BudgetTracking.xcodeproj" \
    -scheme "$SCHEME" \
    clean -quiet

rm -rf "$ARCHIVE_PATH"

# ── Stage 2: Archive ────────────────────────────────────────────────────────

echo "=== Stage 2/7: Building archive..."
xcodebuild -project "$PROJECT_DIR/BudgetTracking.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    archive -quiet

# ── Stage 3: Export + Notarize ───────────────────────────────────────────────

cat > "$EXPORT_OPTIONS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>98AUV869NF</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
EOF

echo "=== Stage 3/7: Exporting and notarizing (this may take a few minutes)..."
rm -rf "$EXPORT_PATH"
mkdir -p "$EXPORT_PATH"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    -quiet

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Export failed — $APP_PATH not found"
    exit 1
fi

# ── Stage 4: Verify ─────────────────────────────────────────────────────────

echo "=== Stage 4/7: Verifying notarization..."
spctl --assess --verbose --type execute "$APP_PATH"

# ── Stage 5: Extract Version ────────────────────────────────────────────────

echo "=== Stage 5/7: Reading version..."
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${PROJECT_DIR}/Exports/${DMG_NAME}"
echo "    Version: ${VERSION} (${BUILD})"

# ── Stage 6: Create DMG ─────────────────────────────────────────────────────

echo "=== Stage 6/7: Creating DMG..."
rm -rf "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" \
    -quiet

rm -rf "$DMG_STAGING"

# ── Stage 7: Deliver to iCloud Drive ────────────────────────────────────────

echo "=== Stage 7/7: Delivering to iCloud Drive..."
mkdir -p "$DELIVERY_DIR"
cp "$DMG_PATH" "$DELIVERY_DIR/"

echo ""
echo "========================================="
echo "  Done! ${APP_NAME} ${VERSION} (${BUILD})"
echo "========================================="
echo "  DMG:    ${DMG_PATH}"
echo "  iCloud: ${DELIVERY_DIR}/${DMG_NAME}"
echo "========================================="

open -R "$DELIVERY_DIR/${DMG_NAME}"
