#!/bin/bash
# Release: build (Developer ID, hardened runtime) → notarize + staple the app → zip → DMG → notarize + staple
# → Sparkle appcast. Upload everything in release/v$VERSION/ to the GitHub release.
#   ./script/package_release.sh                 full release
#   SKIP_NOTARIZE=1 ./script/package_release.sh  local check of the zip/DMG only
# Asset names stay stable: the site picks the *-macos-arm64.zip from releases/latest.
# NOTES_FILE (default release/notes-v$VERSION.md, "## 中文 … ## English …") becomes the update window's notes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
KINDLE_BUILD_CONFIGURATION=release ./script/build_and_run.sh --build-only
APP="$ROOT_DIR/mac-app/dist/乔木 Kindle 助手.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
ARCH=$(/usr/bin/uname -m)
OUT="$ROOT_DIR/release/v$VERSION"; rm -rf "$OUT"; mkdir -p "$OUT"
ZIP="$OUT/KindlePush-$VERSION-macos-$ARCH.zip"
DMG="$OUT/KindlePush-$VERSION-macos-$ARCH.dmg"
PROFILE="${NOTARY_PROFILE:-notary}"
IDENTITY=$(/usr/bin/security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')
[ -n "$IDENTITY" ] || { echo "需要 Developer ID Application 证书"; exit 1; }
/usr/bin/codesign --verify --strict "$APP"

# 1. Notarize the app itself, so the zip download opens without a warning.
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  /usr/bin/ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait
  rm "$OUT/notarize.zip"
  xcrun stapler staple "$APP"
  /usr/sbin/spctl --assess --type execute -vv "$APP"
fi
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"

# 2. DMG with drag-to-Applications layout.
VENV="$ROOT_DIR/mac-app/.build/dmg-venv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then python3 -m venv "$VENV"; "$VENV/bin/pip" install --quiet "dmgbuild==1.6.5"; fi
swift script/dmg/dmg-background.swift "$OUT/bg.png" "$OUT/bg@2x.png" "装好后会自动检查更新"
tiffutil -cathidpicheck "$OUT/bg.png" "$OUT/bg@2x.png" -out "$OUT/bg.tiff" >/dev/null
"$VENV/bin/dmgbuild" -s script/dmg/dmg-settings.py -D app="$APP" -D background="$OUT/bg.tiff" "乔木 Kindle 助手" "$DMG"
rm -f "$OUT"/bg*
/usr/bin/codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  /usr/sbin/spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi
cp "$DMG" "$OUT/KindlePush.dmg"   # fixed name for releases/latest/download/KindlePush.dmg

# 3. Sparkle appcast, signed after stapling (stapling changes the bytes).
SIG=$("$ROOT_DIR/mac-app/.build/artifacts/sparkle/Sparkle/bin/sign_update" "$DMG")
NOTES_HTML=$(python3 - "${NOTES_FILE:-$ROOT_DIR/release/notes-v$VERSION.md}" <<'PY'
import html, re, sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text() if p.exists() else ""
zh = text.split("## English")[0].replace("## 中文", "").strip()
out = []
for line in zh.splitlines():
    line = html.escape(line.strip())
    line = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", line)
    if line.startswith("- "): out.append(f"<li>{line[2:]}</li>")
    elif line: out.append(f"<p>{line}</p>")
print("\n".join(out))
PY
)
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>乔木 Kindle 助手</title>
    <item>
      <title>乔木 Kindle 助手 $VERSION</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/joeseesun/kindle-push-macos/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/joeseesun/kindle-push-macos/releases/download/v$VERSION/$(basename "$DMG")" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT/appcast.xml"
cd "$OUT" && /usr/bin/shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" KindlePush.dmg > SHA256SUMS
ls -la "$OUT"
