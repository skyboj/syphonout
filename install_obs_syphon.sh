#!/bin/bash
set -e

PLUGIN_DIR="$HOME/Library/Application Support/obs-studio/plugins"
TMP_DIR=$(mktemp -d)

echo "Downloading obs-syphon..."

# Get latest release download URL
RELEASE_URL=$(curl -s https://api.github.com/repos/zakk4223/obs-syphon/releases/latest \
  | grep "browser_download_url" \
  | grep ".zip" \
  | cut -d '"' -f 4)

if [ -z "$RELEASE_URL" ]; then
  echo "ERROR: Could not find release. Check https://github.com/zakk4223/obs-syphon/releases"
  exit 1
fi

curl -L "$RELEASE_URL" -o "$TMP_DIR/obs-syphon.zip"
unzip -q "$TMP_DIR/obs-syphon.zip" -d "$TMP_DIR/extracted"

mkdir -p "$PLUGIN_DIR"
cp -R "$TMP_DIR/extracted/"* "$PLUGIN_DIR/"

rm -rf "$TMP_DIR"

echo "✓ obs-syphon installed to: $PLUGIN_DIR"
echo "→ Restart OBS, then go to Tools → Syphon Output to enable"
echo ""
echo "If OBS shows a plugin load error, run:"
echo "  xattr -dr com.apple.quarantine \"$PLUGIN_DIR/obs-syphon\""
