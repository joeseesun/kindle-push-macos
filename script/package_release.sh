#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
KINDLE_BUILD_CONFIGURATION=release ./script/build_and_run.sh --build-only
APP="$ROOT_DIR/mac-app/dist/乔木 Kindle 助手.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH=$(/usr/bin/uname -m)
mkdir -p "$ROOT_DIR/release"
NAME="KindlePush-$VERSION-macos-$ARCH.zip"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ROOT_DIR/release/$NAME"
cd "$ROOT_DIR/release"
/usr/bin/shasum -a 256 "$NAME" > SHA256SUMS
printf 'Release: %s\n' "$ROOT_DIR/release/$NAME"
