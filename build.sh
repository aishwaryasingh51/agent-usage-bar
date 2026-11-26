#!/bin/bash
# Build AgentUsageBar.app into ~/Applications (ad-hoc signed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${INSTALL_DIR:-$HOME/Applications}/AgentUsageBar.app"
# VERSION: line 1 = marketing version, line 2 = build number.
VERSION="$(sed -n 1p "$ROOT/VERSION" | tr -d '[:space:]')"
BUILD_NUMBER="$(sed -n 2p "$ROOT/VERSION" | tr -d '[:space:]')"
# Where the in-app updater looks for new releases (owner/repo): AUB_UPDATE_REPO, else this
# checkout's GitHub origin (so forks update from themselves), else the upstream repo.
UPDATE_REPO="${AUB_UPDATE_REPO:-}"
if [ -z "$UPDATE_REPO" ]; then
  ORIGIN="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  ORIGIN="${ORIGIN%/}"; ORIGIN="${ORIGIN%.git}"
  UPDATE_REPO="$(printf '%s' "$ORIGIN" | sed -nE 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$#\2#p')"
fi
if ! printf '%s' "$UPDATE_REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  UPDATE_REPO="aishwaryasingh51/agent-usage-bar"
fi
# AUB_TEST_BUILD=1 compiles in the updater's test hooks (env/flag overrides). Never use it for a real install.
SWIFT_EXTRA=()
if [ "${AUB_TEST_BUILD:-}" = 1 ]; then SWIFT_EXTRA=(-Xswiftc -DAUB_TEST_HOOKS); fi
cd "$ROOT/App"
echo "let appVersion = \"$VERSION\"  // generated from VERSION by build.sh" > Sources/AgentUsageBar/Version.swift
swift build -c release --arch arm64 ${SWIFT_EXTRA[@]+"${SWIFT_EXTRA[@]}"}
BIN="$(swift build -c release --arch arm64 ${SWIFT_EXTRA[@]+"${SWIFT_EXTRA[@]}"} --show-bin-path)/AgentUsageBar"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/collectors" "$APP/Contents/Resources/Icons"
cp "$BIN" "$APP/Contents/MacOS/AgentUsageBar"
cp "$ROOT"/collectors/agent-usage-* "$APP/Contents/Resources/collectors/"
chmod +x "$APP"/Contents/Resources/collectors/*
cp "$ROOT"/App/Resources/Icons/*-template.svg "$APP/Contents/Resources/Icons/"
cp "$ROOT/App/Resources/aub-swap.sh" "$APP/Contents/Resources/aub-swap.sh"
chmod +x "$APP/Contents/Resources/aub-swap.sh"
cp -R "$ROOT/docs/demo" "$APP/Contents/Resources/demo"
# App icon: optional. If Resources/AppIcon.png (1024x1024) exists, build AppIcon.icns from it.
ICON_PLIST=""
if [ -f "$ROOT/Resources/AppIcon.png" ]; then
  ICONTMP="$(mktemp -d)"
  ICONSET="$ICONTMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz * 2)) $((sz * 2)) "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONTMP"
  ICON_PLIST="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.aishwaryasingh51.agent-usage-bar</string>
<key>CFBundleName</key><string>Agent Usage Bar</string>
<key>CFBundleExecutable</key><string>AgentUsageBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>AUBUpdateRepo</key><string>$UPDATE_REPO</string>
$ICON_PLIST
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
