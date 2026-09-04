#!/bin/bash
# Build GhosttyKit.xcframework from the Ghostty submodule.
# Output: GhosttyKit.xcframework/ in the repo root (copied from ghostty/macos/).
#
# Prerequisites:
#   - Zig 0.16.x (Homebrew: brew install zig)
#   - Xcode with the Metal Toolchain component:
#       xcodebuild -downloadComponent MetalToolchain
#     If that download fails (Apple catalog errors on some networks), the
#     system MetalToolchain cryptex can be used directly instead — see
#     SYNAPTY_METAL_DIR below.
#   - ghostty/ checkout at the pinned commit (see ghostty git log)
#
# Usage:
#   ./scripts/build-ghosttykit.sh              # ReleaseFast (default)
#   ./scripts/build-ghosttykit.sh Debug        # Debug build
#
# Workaround for missing Metal Toolchain component:
#   The toolchain ships as a system asset cryptex; mount it and point
#   SYNAPTY_METAL_DIR at its usr/bin:
#     hdiutil attach -readonly -nobrowse \
#       /System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/*/AssetData/Restore/*.dmg
#     SYNAPTY_METAL_DIR=/Volumes/MetalToolchainCryptex/Metal.xctoolchain/usr/bin \
#       ./scripts/build-ghosttykit.sh
#   (The local ghostty patch "allow overriding metal compiler via
#   SYNAPTY_METAL_DIR" makes `zig build` honor this; it is one of the
#   patches/*.patch this script applies.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/ghostty"
OPTIMIZE="${1:-ReleaseFast}"

if [ ! -f "$GHOSTTY_DIR/build.zig" ]; then
    echo "Error: ghostty not found at $GHOSTTY_DIR"
    echo "Run: git -C ghostty fetch origin main && git -C ghostty checkout <pinned-commit>"
    exit 1
fi

# Ghostty deps are fetched from deps.files.ghostty.org; zig's HTTP client can
# drop connections when fetching many packages concurrently. If the build
# fails with HttpConnectionClosing/WriteFailed, pre-fetch all deps serially:
#   for u in $(grep -rhoE '\.url = "[^"]+"' ghostty/build.zig.zon ghostty/pkg/*/build.zig.zon | cut -d'"' -f2); do
#     zig fetch "$u"
#   done

# Clean previous xcframework output (xcodebuild -create-xcframework fails if it exists)
rm -rf "$GHOSTTY_DIR/macos/GhosttyKit.xcframework"

echo "Building GhosttyKit.xcframework (optimize=$OPTIMIZE)..."
cd "$GHOSTTY_DIR"

# EVERY LOCAL PATCH, APPLIED HERE, IDEMPOTENTLY ([[WI-2026-09-02-017]]).
# The submodule tracks UPSTREAM ghostty (WI-2026-08-08-087); what Synapty
# needs changed lives in patches/*.patch and is applied by this script —
# not by a step a human remembers. The surface-opts patch (the fix without
# which a surface's command, cwd and env are discarded on conditional-state
# re-derivation, WI-2026-08-09-025) used to exist only as an uncommitted
# edit in the submodule plus a line in CLAUDE.md; a fresh clone built a
# GhosttyKit without it and nothing said so. While the patches are
# unmerged upstream the submodule is dirty BY DESIGN after this runs;
# `git -C ghostty apply --reverse ../patches/*.patch` takes it back.
for PATCH in "$REPO_ROOT"/patches/*.patch; do
    if git apply --reverse --check "$PATCH" >/dev/null 2>&1; then
        echo "Local patch already applied: $(basename "$PATCH")"
    elif git apply --check "$PATCH" >/dev/null 2>&1; then
        echo "Applying local patch: $(basename "$PATCH")"
        git apply "$PATCH"
    else
        echo "Error: patch neither applied nor applicable: $PATCH" >&2
        echo "       The submodule is at a commit the patch does not fit, or has other edits." >&2
        exit 1
    fi
done

if [ -n "${SYNAPTY_METAL_DIR:-}" ]; then
    echo "Using Metal toolchain: $SYNAPTY_METAL_DIR"
    export SYNAPTY_METAL_DIR
    export SYNAPTY_METAL_CACHE="${SYNAPTY_METAL_CACHE:-$REPO_ROOT/.zig-cache-ghostty/metal-cache}"
fi

# -Dsentry=false IS NOT OPTIONAL, and this script omitted it while the
# build instructions it automates required it. Ghostty's embedded Sentry
# reporter (a) sends crashes from OUR application to ghostty's DSN, which
# is somebody else's inbox receiving our users' stack traces, and (b) its
# own init thread SIGSEGVed intermittently at launch — two identical .ips
# on 2026-08-10. A framework built by this script rather than by hand
# carried both.
zig build \
    -Demit-xcframework=true \
    -Dxcframework-target=universal \
    -Dsentry=false \
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
