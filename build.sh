#!/bin/bash
# Build AgentUsageBar.app into ~/Applications (ad-hoc signed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${INSTALL_DIR:-$HOME/Applications}/AgentUsageBar.app"
cd "$ROOT/App"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/AgentUsageBar"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/collectors" "$APP/Contents/Resources/Icons"
cp "$BIN" "$APP/Contents/MacOS/AgentUsageBar"
cp "$ROOT"/collectors/agent-usage-* "$APP/Contents/Resources/collectors/"
chmod +x "$APP"/Contents/Resources/collectors/*
cp "$ROOT"/App/Resources/Icons/*-template.svg "$APP/Contents/Resources/Icons/"
cp -R "$ROOT/docs/demo" "$APP/Contents/Resources/demo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.aishwaryasingh51.agent-usage-bar</string>
<key>CFBundleName</key><string>Agent Usage Bar</string>
<key>CFBundleExecutable</key><string>AgentUsageBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
