#!/bin/sh
set -eu

OWNER="${DOCKMOVE_OWNER:-KonradStanski}"
REPO="${DOCKMOVE_REPO:-dockmove}"
INSTALL_ROOT="${DOCKMOVE_INSTALL_ROOT:-$HOME/.local/opt/dockmove}"
BIN_DIR="${DOCKMOVE_BIN_DIR:-$HOME/.local/bin}"
ASSET_SUFFIX="macos-arm64.tar.gz"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

need_cmd curl
need_cmd tar

[ "$(uname -s)" = "Darwin" ] || fail "dockmove only supports macOS"
[ "$(uname -m)" = "arm64" ] || fail "this build currently supports Apple Silicon only"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

API_URL="https://api.github.com/repos/$OWNER/$REPO/releases/latest"
ASSET_URL="$(curl -fsSL "$API_URL" | awk -F'"' '/browser_download_url/ && /'"$ASSET_SUFFIX"'/ { print $4; exit }')"
[ -n "$ASSET_URL" ] || fail "could not find a release asset ending in $ASSET_SUFFIX"

ARCHIVE="$TMP_DIR/dockmove.tar.gz"
curl -fL "$ASSET_URL" -o "$ARCHIVE"

mkdir -p "$INSTALL_ROOT" "$BIN_DIR"
tar -xzf "$ARCHIVE" -C "$TMP_DIR"

PACKAGE_DIR="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$PACKAGE_DIR" ] || fail "release archive did not contain a package directory"

cp "$PACKAGE_DIR/dockmove" "$INSTALL_ROOT/dockmove"
cp "$PACKAGE_DIR/dockmove-payload.dylib" "$INSTALL_ROOT/dockmove-payload.dylib"
cp "$PACKAGE_DIR/README.md" "$INSTALL_ROOT/README.md"
cp "$PACKAGE_DIR/LICENSE" "$INSTALL_ROOT/LICENSE"

chmod 755 "$INSTALL_ROOT/dockmove"
chmod 755 "$INSTALL_ROOT/dockmove-payload.dylib"
ln -sf "$INSTALL_ROOT/dockmove" "$BIN_DIR/dockmove"

xattr -dr com.apple.quarantine "$INSTALL_ROOT" 2>/dev/null || true
codesign -s - --force "$INSTALL_ROOT/dockmove" >/dev/null 2>&1 || true
codesign -s - --force "$INSTALL_ROOT/dockmove-payload.dylib" >/dev/null 2>&1 || true

printf '\nInstalled dockmove to %s\n' "$INSTALL_ROOT"
printf 'Binary symlink: %s/dockmove\n' "$BIN_DIR"

cat <<'EOF'

Manual setup still required before injection works:

1. Boot into Recovery.
2. Open Utilities > Terminal.
3. Run:
   csrutil enable --without fs --without debug --without nvram
4. Reboot normally.
5. Run:
   sudo nvram boot-args=-arm64e_preview_abi
6. Reboot again.
7. In System Settings > Desktop & Dock > Mission Control:
   - Displays have separate Spaces = On
   - Automatically rearrange Spaces based on most recent use = Off
8. Inject the payload into Dock:
   sudo dockmove inject

Then use:
  dockmove list-spaces
  dockmove list-windows
  dockmove move-window --window-id <id> --space-id <sid>
EOF
