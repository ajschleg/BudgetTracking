#!/bin/bash
# Build and export BudgetTracking.app for distribution
# Usage: ./scripts/distribute.sh

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE_PATH="/tmp/BudgetTracking.xcarchive"
EXPORT_PATH="$HOME/Desktop/BudgetTracking-Export"
EXPORT_OPTIONS="/tmp/BudgetTracking-ExportOptions.plist"

echo "Cleaning build folder..."
xcodebuild -project "$PROJECT_DIR/BudgetTracking.xcodeproj" \
    -scheme BudgetTracking \
    clean -quiet

rm -rf "$ARCHIVE_PATH"

echo "Building archive..."
xcodebuild -project "$PROJECT_DIR/BudgetTracking.xcodeproj" \
    -scheme BudgetTracking \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    archive -quiet

# Create export options plist
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
</dict>
</plist>
EOF

echo "Exporting app..."
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -quiet

echo ""
echo "Done! App exported to: $EXPORT_PATH/BudgetTracking.app"
echo "Send this file to your wife to install."
