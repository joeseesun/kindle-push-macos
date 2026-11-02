#!/bin/bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/mac-app/dist/Kindle 推送.app"
CONTENTS="$APP_BUNDLE/Contents"
if [ "$MODE" != "--build-only" ]; then /usr/bin/pkill -x KindlePush >/dev/null 2>&1 || true; fi
cd "$ROOT_DIR/mac-app"
BUILD_CONFIGURATION="${KINDLE_BUILD_CONFIGURATION:-debug}"
SWIFT_FLAGS=(-Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=.")
if [ "$BUILD_CONFIGURATION" = "release" ]; then
    SWIFT_FLAGS+=(-Xswiftc -gnone)
else
    SWIFT_FLAGS+=(-Xswiftc -debug-prefix-map -Xswiftc "$ROOT_DIR=.")
fi
swift build -c "$BUILD_CONFIGURATION" "${SWIFT_FLAGS[@]}"
BUILD_DIR="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
rm -rf "$CONTENTS/Resources/__pycache__"
cp "$BUILD_DIR/KindlePush" "$CONTENTS/MacOS/KindlePush"
cp "$ROOT_DIR/wifi-push/kindle_push.py" "$ROOT_DIR/wifi-push/app_bridge.py" "$ROOT_DIR/wifi-push/markdown_support.py" "$ROOT_DIR/wifi-push/ebook.css" "$CONTENTS/Resources/"
cp "$ROOT_DIR/wifi-push/translation.py" "$ROOT_DIR/wifi-push/accounts.py" "$CONTENTS/Resources/"
cp "$ROOT_DIR/mac-app/Assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KindlePush</string>
<key>CFBundleIdentifier</key><string>local.chase.KindlePush</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
<key>CFBundleName</key><string>Kindle 推送</string>
<key>CFBundleDisplayName</key><string>Kindle 推送</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.4.0</string>
<key>CFBundleVersion</key><string>6</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>在当前 Wi-Fi 中寻找已配对 Kindle 并发送你选择的文章。</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>可推送文章与电子书</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>CFBundleTypeExtensions</key><array><string>epub</string><string>md</string><string>markdown</string><string>txt</string><string>html</string><string>htm</string><string>xhtml</string><string>docx</string><string>odt</string><string>rtf</string><string>pdf</string><string>xps</string><string>djvu</string><string>djv</string><string>cbz</string><string>cbr</string><string>cbt</string><string>mobi</string><string>azw</string><string>azw3</string><string>prc</string><string>pdb</string><string>tcr</string><string>fb2</string><string>fb3</string><string>chm</string><string>doc</string><string>docm</string><string>htmlz</string></array>
</dict></array>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP_BUNDLE"
case "$MODE" in
  --build-only) ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; /usr/bin/pgrep -x KindlePush >/dev/null ;;
  --debug) lldb -- "$CONTENTS/MacOS/KindlePush" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "KindlePush"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.chase.KindlePush"' ;;
  *) echo 'usage: build_and_run.sh [--build-only|--verify|--debug|--logs|--telemetry]' >&2; exit 2 ;;
esac
