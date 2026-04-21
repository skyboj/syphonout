#!/bin/bash
# build.sh — build and optionally install obs-solink
# Usage:
#   ./build.sh          — build (Release)
#   ./build.sh install  — build + install to OBS user plugins
#   ./build.sh clean    — clean build directory
#   ./build.sh debug    — build (Debug)

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
MODE="${1:-build}"
CONFIG="Release"
[ "$MODE" = "debug" ] && CONFIG="Debug"

case "$MODE" in
  clean)
    echo "🧹 Cleaning build..."
    rm -rf "$BUILD_DIR"
    echo "✅ Done"
    exit 0
    ;;
  build|debug|install)
    ;;
  *)
    echo "Usage: $0 [build|debug|install|clean]"
    exit 1
    ;;
esac

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Configure if needed
if [ ! -f "CMakeCache.txt" ]; then
    echo "⚙️  Configuring..."
    cmake "$SCRIPT_DIR" -DCMAKE_BUILD_TYPE="$CONFIG"
fi

echo "🔨 Building (${CONFIG})..."
cmake --build . --config "$CONFIG" -j"$(sysctl -n hw.ncpu)"

echo ""
echo "✅ Build complete: $BUILD_DIR/obs-solink.plugin"

if [ "$MODE" = "install" ]; then
    echo "📦 Installing to OBS plugins..."
    cmake --install .
    echo "✅ Installed. Restart OBS to load the plugin."
fi
