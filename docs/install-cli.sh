#!/bin/sh
# Installs the dabble command-line tool and MCP server for AI agents.
#   curl -fsSL https://nearbycoder.github.io/dabble/install-cli.sh | sh
# If Dabble.app is in /Applications, this links the copy inside it instead of downloading.
set -eu
DEST="${DABBLE_BIN_DIR:-/usr/local/bin}"
BUNDLED="/Applications/Dabble.app/Contents/Helpers/dabble"
SUDO=""
if [ ! -w "$DEST" ] 2>/dev/null || [ ! -d "$DEST" ]; then SUDO="sudo"; fi
$SUDO mkdir -p "$DEST"
if [ -x "$BUNDLED" ]; then
  echo "Linking the dabble tool from Dabble.app into $DEST…"
  $SUDO ln -sf "$BUNDLED" "$DEST/dabble"
else
  echo "Downloading the dabble tool…"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/dabble.zip" https://github.com/nearbycoder/dabble/releases/latest/download/dabble-cli-macOS.zip
  ditto -x -k "$TMP/dabble.zip" "$TMP"
  $SUDO install -m 0755 "$TMP/dabble" "$DEST/dabble"
fi
"$DEST/dabble" --version
echo
echo "Next: connect it to your to-dos with  dabble join <sync key>"
echo "(Dabble → Settings → Agents shows the exact command), or run  dabble pair"
