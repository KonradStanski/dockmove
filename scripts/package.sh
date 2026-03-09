#!/bin/zsh
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
DIST_DIR="$ROOT/dist"
VERSION="${1:-dev}"
PACKAGE_NAME="dockmove-${VERSION}-macos-arm64"
PACKAGE_DIR="$DIST_DIR/$PACKAGE_NAME"

"$ROOT/build.sh"

rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"

cp "$ROOT/build/dockmove" "$PACKAGE_DIR/dockmove"
cp "$ROOT/build/dockmove-payload.dylib" "$PACKAGE_DIR/dockmove-payload.dylib"
cp "$ROOT/README.md" "$PACKAGE_DIR/README.md"
cp "$ROOT/LICENSE" "$PACKAGE_DIR/LICENSE"

cd "$DIST_DIR"
tar -czf "${PACKAGE_NAME}.tar.gz" "$PACKAGE_NAME"
shasum -a 256 "${PACKAGE_NAME}.tar.gz" > "${PACKAGE_NAME}.tar.gz.sha256"

echo "$DIST_DIR/${PACKAGE_NAME}.tar.gz"
