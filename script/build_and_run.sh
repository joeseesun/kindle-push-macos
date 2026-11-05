#!/bin/bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Built aside and swapped in at the end. Never write into the bundle in place: overwriting the
# binary of a copy that is running makes macOS kill it (SIGKILL, Code Signature Invalid).
# KINDLE_ARCH=x86_64 builds the Intel version from an Apple silicon Mac, in a folder of its own.
TARGET_ARCH="${KINDLE_ARCH:-$(/usr/bin/uname -m)}"
DIST="$ROOT_DIR/mac-app/dist"
if [ "$TARGET_ARCH" != "$(/usr/bin/uname -m)" ]; then DIST="$ROOT_DIR/mac-app/dist-$TARGET_ARCH"; fi
FINAL_BUNDLE="$DIST/乔木 Kindle 助手.app"
STAGE="$DIST/.staging"
rm -rf "$STAGE"; mkdir -p "$STAGE"
APP_BUNDLE="$STAGE/乔木 Kindle 助手.app"
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
swift build -c "$BUILD_CONFIGURATION" --arch "$TARGET_ARCH" "${SWIFT_FLAGS[@]}"
BUILD_DIR="$(swift build -c "$BUILD_CONFIGURATION" --arch "$TARGET_ARCH" --show-bin-path)"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
rm -rf "$CONTENTS/Resources/__pycache__"
cp "$BUILD_DIR/KindlePush" "$CONTENTS/MacOS/KindlePush"
# Sparkle: embed the framework and let the binary find it.
rm -rf "$CONTENTS/Frameworks"; mkdir -p "$CONTENTS/Frameworks"
/usr/bin/ditto "$BUILD_DIR/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"
if ! /usr/bin/otool -l "$CONTENTS/MacOS/KindlePush" | grep -q "@executable_path/../Frameworks"; then
  /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/KindlePush"
fi
cp "$ROOT_DIR/wifi-push/kindle_push.py" "$ROOT_DIR/wifi-push/app_bridge.py" "$ROOT_DIR/wifi-push/markdown_support.py" "$ROOT_DIR/wifi-push/devices.py" "$ROOT_DIR/wifi-push/setup_device.py" "$ROOT_DIR/wifi-push/kindle-receive.sh" "$ROOT_DIR/wifi-push/ebook.css" "$CONTENTS/Resources/"
cp "$ROOT_DIR/wifi-push/translation.py" "$ROOT_DIR/wifi-push/storage.py" "$ROOT_DIR/wifi-push/accounts.py" "$ROOT_DIR/wifi-push/bookinfo.py" "$ROOT_DIR/wifi-push/names.py" "$ROOT_DIR/wifi-push/terms.py" "$ROOT_DIR/wifi-push/chunks.py" "$ROOT_DIR/wifi-push/polish.py" "$ROOT_DIR/wifi-push/pdfpages.py" "$ROOT_DIR/wifi-push/languages.py" "$CONTENTS/Resources/"
cp "$ROOT_DIR/mac-app/Assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
# About tab: QR codes (bundled so they work offline) and third-party licenses.
rm -rf "$CONTENTS/Resources/About"; cp -R "$ROOT_DIR/mac-app/Assets/About" "$CONTENTS/Resources/About"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$ROOT_DIR/LICENSE" "$CONTENTS/Resources/"
# English interface (see I18n.swift). en.lproj makes macOS treat the app as localized, so its own menu follows.
cp "$ROOT_DIR/mac-app/Assets/i18n/en.tsv" "$CONTENTS/Resources/en.tsv"
mkdir -p "$CONTENTS/Resources/en.lproj" "$CONTENTS/Resources/zh-Hans.lproj"
cp "$ROOT_DIR/mac-app/Assets/i18n/InfoPlist.strings" "$CONTENTS/Resources/en.lproj/InfoPlist.strings"
# Ink accent (no system blue). Compiled from mac-app/Assets/Colors.xcassets by script/make_assets.sh.
cp "$ROOT_DIR/mac-app/Assets/Assets.car" "$CONTENTS/Resources/Assets.car"
# Python and Pandoc, so nothing has to be installed. A release must have them (./script/fetch_runtime.sh);
# a dev build without them falls back to Homebrew's.
VENDOR="$ROOT_DIR/mac-app/vendor/$TARGET_ARCH"
if [ "$BUILD_CONFIGURATION" = "release" ] || [ -d "$VENDOR" ]; then
  "$ROOT_DIR/script/fetch_runtime.sh" "$TARGET_ARCH"
  mkdir -p "$CONTENTS/Resources/runtime"
  /usr/bin/ditto "$VENDOR/python" "$CONTENTS/Resources/runtime/python"
  cp "$VENDOR/pandoc" "$CONTENTS/Resources/runtime/pandoc"
fi
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KindlePush</string>
<key>CFBundleIdentifier</key><string>local.chase.KindlePush</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
<key>CFBundleName</key><string>乔木 Kindle 助手</string>
<key>CFBundleDisplayName</key><string>乔木 Kindle 助手</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.17.1</string>
<key>CFBundleVersion</key><string>24</string>
<key>SUFeedURL</key><string>https://github.com/joeseesun/kindle-push-macos/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>ftyDAv8Qvb8tv4nf5jnMWtCgIi9yVI2IM6p+qhrKz90=</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>NSHumanReadableCopyright</key><string>© 2026 向阳乔木</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSAccentColorName</key><string>AccentColor</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
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
# Intel has its own update feed, so an update never brings the wrong architecture.
if [ "$TARGET_ARCH" = "x86_64" ]; then
  /usr/libexec/PlistBuddy -c 'Set :SUFeedURL https://github.com/joeseesun/kindle-push-macos/releases/latest/download/appcast-intel.xml' "$CONTENTS/Info.plist"
fi
# Developer ID + hardened runtime on every build, so permissions survive rebuilds; ad-hoc only without the certificate.
IDENTITY=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
TS="--timestamp=none"; if [ "$BUILD_CONFIGURATION" = "release" ]; then TS="--timestamp"; fi
# Nested code first (Sparkle's documented order), never --deep.
SPK="$CONTENTS/Frameworks/Sparkle.framework/Versions/B"
for item in "$SPK/XPCServices/Installer.xpc" "$SPK/XPCServices/Downloader.xpc" "$SPK/Autoupdate" "$SPK/Updater.app" \
            "$CONTENTS/Frameworks/Sparkle.framework"; do
  if [ -e "$item" ]; then /usr/bin/codesign --force --options runtime $TS --preserve-metadata=entitlements --sign "${IDENTITY:--}" "$item"; fi
done
# Everything executable inside the runtime, libraries first. Python needs library validation off:
# the translation engine's wheels are installed later, by pip, and carry no signature of ours.
RUNTIME="$CONTENTS/Resources/runtime"
if [ -d "$RUNTIME" ]; then
  /usr/bin/find "$RUNTIME/python" -type f \( -name '*.so' -o -name '*.dylib' \) -print0 |
    /usr/bin/xargs -0 -P 8 -n 8 /usr/bin/codesign --force --options runtime $TS --sign "${IDENTITY:--}"
  /usr/bin/codesign --force --options runtime $TS --sign "${IDENTITY:--}" "$RUNTIME/pandoc"
  /usr/bin/codesign --force --options runtime $TS --entitlements "$ROOT_DIR/script/python.entitlements" --sign "${IDENTITY:--}" \
    "$(/usr/bin/readlink -f "$RUNTIME/python/bin/python3")"
fi
/usr/bin/codesign --force --options runtime $TS --sign "${IDENTITY:--}" "$APP_BUNDLE"
# The swap: a running copy keeps the files it has open; the next launch gets the new build.
if [ -e "$FINAL_BUNDLE" ]; then mv "$FINAL_BUNDLE" "$STAGE/previous.app"; fi
mv "$APP_BUNDLE" "$FINAL_BUNDLE"
rm -rf "$STAGE"
APP_BUNDLE="$FINAL_BUNDLE"; CONTENTS="$APP_BUNDLE/Contents"
case "$MODE" in
  --build-only) ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; /usr/bin/pgrep -x KindlePush >/dev/null ;;
  --debug) lldb -- "$CONTENTS/MacOS/KindlePush" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "KindlePush"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.chase.KindlePush"' ;;
  *) echo 'usage: build_and_run.sh [--build-only|--verify|--debug|--logs|--telemetry]' >&2; exit 2 ;;
esac
