#!/bin/bash
# Fetches the Python and Pandoc the app carries, so users install nothing. Versions and hashes are
# pinned: a bump is a reviewed change here. Output goes to mac-app/vendor/<arch>/ (not in git).
#   ./script/fetch_runtime.sh [arm64|x86_64]    default: this Mac's architecture
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-$(/usr/bin/uname -m)}"
PY_TAG=20261026
PY_VERSION=3.13.18
PANDOC_VERSION=3.13
case "$ARCH" in
  arm64)
    PY_ARCH=aarch64; PY_SHA=8392b6ea51d94391befb2c31ebe75463f045d0b69dfcf5e1bb3234e1f5fa3405
    PANDOC_SHA=f436d18bebbfb3ddd326597686dacab9fac5dc23bd060495020f35a28a43a7c3 ;;
  x86_64)
    PY_ARCH=x86_64; PY_SHA=7412c19d896c99431b74a18a5643e110449a7f9590fbab179c3e5ab27b9aa9e3
    PANDOC_SHA=1823278715aa405aaf21b59cde5dc789346aa8d4fc307467f9a9ee84162bedc5 ;;
  *) echo "unknown architecture: $ARCH" >&2; exit 2 ;;
esac
OUT="$ROOT_DIR/mac-app/vendor/$ARCH"
STAMP="$PY_VERSION+$PY_TAG pandoc-$PANDOC_VERSION"
if [ "$(cat "$OUT/VERSION" 2>/dev/null || true)" = "$STAMP" ]; then exit 0; fi
CACHE="$ROOT_DIR/mac-app/vendor/.downloads"; mkdir -p "$CACHE"

fetch() { # url sha256 file
  local file="$CACHE/$3"
  if [ ! -f "$file" ] || [ "$(/usr/bin/shasum -a 256 "$file" | cut -d' ' -f1)" != "$2" ]; then
    /usr/bin/curl -fL --retry 3 -o "$file" "$1"
  fi
  [ "$(/usr/bin/shasum -a 256 "$file" | cut -d' ' -f1)" = "$2" ] || { echo "hash mismatch: $3" >&2; exit 1; }
}
PY_FILE="cpython-$PY_VERSION+$PY_TAG-$PY_ARCH-apple-darwin-install_only_stripped.tar.gz"
PANDOC_FILE="pandoc-$PANDOC_VERSION-$ARCH-macOS.zip"
fetch "https://github.com/astral-sh/python-build-standalone/releases/download/$PY_TAG/${PY_FILE/+/%2B}" "$PY_SHA" "$PY_FILE"
fetch "https://github.com/jgm/pandoc/releases/download/$PANDOC_VERSION/$PANDOC_FILE" "$PANDOC_SHA" "$PANDOC_FILE"

rm -rf "$OUT"; mkdir -p "$OUT"
/usr/bin/tar -xzf "$CACHE/$PY_FILE" -C "$OUT"
TEMP="$(mktemp -d)"; trap 'rm -rf "$TEMP"' EXIT
/usr/bin/ditto -x -k "$CACHE/$PANDOC_FILE" "$TEMP"
mv "$TEMP/pandoc-$PANDOC_VERSION-$ARCH/bin/pandoc" "$OUT/pandoc"
# Parts of Python this app never uses. ensurepip stays: `venv` needs it for the translation engine.
LIB="$OUT/python/lib/python${PY_VERSION%.*}"
rm -rf "$LIB/test" "$LIB/idlelib" "$LIB/tkinter" "$LIB/turtledemo" "$LIB/lib2to3" "$OUT/python/lib/tcl"* "$OUT/python/lib/tk"* \
       "$OUT/python/lib/itcl"* "$OUT/python/lib/thread"* "$OUT/python/share" "$OUT/python/include"
find "$LIB" -name '_tkinter*' -delete
find "$LIB" -path '*/config-*' -name '*.a' -delete
echo "$STAMP" > "$OUT/VERSION"
du -sh "$OUT/python" "$OUT/pandoc"
