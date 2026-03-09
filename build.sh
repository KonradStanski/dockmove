#!/bin/zsh
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
TMP_DIR="$ROOT/.tmp"
SDKROOT="$(xcrun --show-sdk-path)"

mkdir -p "$BUILD_DIR" "$TMP_DIR"

COMMON_FLAGS=(
  -isysroot "$SDKROOT"
  -Wl,-syslibroot,"$SDKROOT"
  -F/System/Library/PrivateFrameworks
  -fobjc-arc
  -Wall
  -Wextra
  -Werror
  -O2
)

export TMPDIR="$TMP_DIR"

clang "${COMMON_FLAGS[@]}" \
  -dynamiclib \
  -framework Foundation \
  -framework CoreGraphics \
  -framework SkyLight \
  -o "$BUILD_DIR/dockmove-payload.dylib" \
  "$ROOT/src/payload.m"

clang "${COMMON_FLAGS[@]}" \
  -framework AppKit \
  -framework Foundation \
  -framework CoreGraphics \
  -framework SkyLight \
  -o "$BUILD_DIR/dockmove" \
  "$ROOT/src/dockmove.m"

codesign -s - --force "$BUILD_DIR/dockmove-payload.dylib" >/dev/null 2>&1 || true
codesign -s - --force "$BUILD_DIR/dockmove" >/dev/null 2>&1 || true

echo "Built:"
echo "  $BUILD_DIR/dockmove"
echo "  $BUILD_DIR/dockmove-payload.dylib"
