#!/bin/bash
# Build GhosttyKit.xcframework from the Ghostty submodule.
# Output: GhosttyKit.xcframework/ in the repo root (copied from ghostty/zig-out/).
#
# Prerequisites:
#   - Zig 0.15.x (provided by devenv)
#   - ghostty/ submodule initialized
#
# Usage:
#   ./scripts/build-ghosttykit.sh              # ReleaseFast (default)
#   ./scripts/build-ghosttykit.sh debug        # Debug build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/ghostty"
OPTIMIZE="${1:-ReleaseFast}"

if [ ! -f "$GHOSTTY_DIR/build.zig" ]; then
    echo "Error: ghostty submodule not found at $GHOSTTY_DIR"
    echo "Run: git submodule update --init"
    exit 1
fi

# Clean previous xcframework output (xcodebuild -create-xcframework fails if it exists)
rm -rf "$GHOSTTY_DIR/macos/GhosttyKit.xcframework"

echo "Building GhosttyKit.xcframework (optimize=$OPTIMIZE)..."
cd "$GHOSTTY_DIR"
zig build \
    -Demit-xcframework=true \
    -Dxcframework-target=universal \
    -Doptimize="$OPTIMIZE"

# Copy xcframework to repo root for Xcode project linking
XCFW_SRC="$GHOSTTY_DIR/zig-out/macos/GhosttyKit.xcframework"
if [ ! -d "$XCFW_SRC" ]; then
    # Try alternate output path
    XCFW_SRC="$GHOSTTY_DIR/macos/GhosttyKit.xcframework"
fi

if [ -d "$XCFW_SRC" ]; then
    rm -rf "$REPO_ROOT/GhosttyKit.xcframework"
    cp -R "$XCFW_SRC" "$REPO_ROOT/GhosttyKit.xcframework"
    echo "Copied to $REPO_ROOT/GhosttyKit.xcframework"
else
    echo "Warning: xcframework not found at expected paths. Check ghostty/zig-out/ for output."
    ls -la "$GHOSTTY_DIR/zig-out/" 2>/dev/null || true
fi

echo "Done."
