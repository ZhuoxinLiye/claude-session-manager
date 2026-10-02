#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_dir="$root_dir/outputs/ClaudeSessionManager.app"

swift build --package-path "$root_dir" -c release

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$root_dir/.build/out/Products/Release/ClaudeSessionManager" "$app_dir/Contents/MacOS/ClaudeSessionManager"
cp "$root_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Claude Session Manager</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeSessionManager</string>
    <key>CFBundleIdentifier</key>
    <string>local.codex.claude-session-manager</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>Claude Session Manager</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Claude Session Manager opens and focuses Ghostty tabs for remote Claude Code sessions.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Finder metadata inherited from a synced workspace can make a signed app fail
# strict verification as a resource fork. It is not part of the bundle.
if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$app_dir" 2>/dev/null || true
fi
/usr/bin/codesign --force --sign - "$app_dir"

echo "Built $app_dir"
