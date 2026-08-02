# Synapty — The Agent Workbench

# Default: build all Zig executables
default: build

# Build all Zig executables (hub, daemon, cli)
build:
    zig build

# Build individual targets
hub:
    zig build hub

daemon:
    zig build daemon

cli:
    zig build cli

# Run all Zig tests
test:
    zig build test

# Build GhosttyKit xcframework from submodule
ghosttykit:
    https_proxy= http_proxy= ./scripts/build-ghosttykit.sh

# Build GhosttyKit (debug)
ghosttykit-debug:
    https_proxy= http_proxy= ./scripts/build-ghosttykit.sh Debug

# Generate Xcode project from project.yml
xcgen:
    xcodegen generate --spec project.yml

# Build macOS GUI app (Debug)
app: xcgen
    xcodebuild -project Synapty.xcodeproj -scheme Synapty -configuration Debug -destination 'platform=macOS' build

# Build macOS GUI app (Release)
app-release: xcgen
    xcodebuild -project Synapty.xcodeproj -scheme Synapty -configuration Release -destination 'platform=macOS' build

# Run the GUI app
run: app
    open ~/Library/Developer/Xcode/DerivedData/Synapty-*/Build/Products/Debug/Synapty.app

# Full build: Zig + GhosttyKit + GUI app
all: build ghosttykit app

# Governance
gov-check:
    govctl check

gov-render:
    govctl render

gov-status:
    govctl status

# Enter dev environment (legacy Nix devenv — no longer maintained)
dev:
    devenv shell

# Cross-compile all deploy targets
deploy-all:
    zig build deploy-linux-aarch64 deploy-linux-x86_64 deploy-linux-riscv64 deploy-macos-aarch64 deploy-macos-x86_64

# Build and test with the Homebrew zig toolchain
check:
    zig build
    zig build test

# Package a universal macOS installer DMG with the GUI app and all deploy targets.
# xcodebuild runs natively. Zig cross-compile runs natively too (zig on PATH).
package:
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION="${SYNAPTY_VERSION:-0.1.0}"
    DMG_NAME="Synapty-${VERSION}-universal"
    STAGE="zig-out/package/${DMG_NAME}"

    echo "==> Building Release GUI app..."
    xcodegen generate --spec project.yml
    xcodebuild -project Synapty.xcodeproj -scheme Synapty -configuration Release \
        -destination 'platform=macOS' build

    echo "==> Cross-compiling deploy targets..."
    zig build deploy-linux-aarch64 deploy-linux-x86_64 deploy-linux-riscv64 \
        deploy-macos-aarch64 deploy-macos-x86_64

    echo "==> Assembling DMG staging area..."
    rm -rf "$STAGE" "zig-out/package/${DMG_NAME}.dmg" "zig-out/package/${DMG_NAME}-rw.dmg"
    mkdir -p "$STAGE/.deploy"

    # Find the most recently built Synapty.app (sorted by modification time)
    APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Synapty-*/Build/Products/Release \
        -name 'Synapty.app' -maxdepth 1 -print0 2>/dev/null \
        | xargs -0 ls -dt 2>/dev/null | head -1)
    if [ -z "$APP_PATH" ]; then
        echo "Error: Synapty.app not found in DerivedData." && exit 1
    fi
    cp -R "$APP_PATH" "$STAGE/"
    echo "    Synapty.app: $APP_PATH"

    # Applications symlink for drag-to-install
    ln -s /Applications "$STAGE/Applications"

    # Copy all deploy binaries (hidden in .deploy so DMG window stays clean)
    for target in linux-aarch64 linux-x86_64 linux-riscv64 macos-aarch64 macos-x86_64; do
        if [ ! -f "zig-out/$target/synapty" ]; then
            echo "Error: zig-out/$target/synapty not found. Run deploy-all first." && exit 1
        fi
        mkdir -p "$STAGE/.deploy/$target"
        cp "zig-out/$target/synapty" "$STAGE/.deploy/$target/"
        echo "    .deploy/$target/synapty: $(ls -lh "zig-out/$target/synapty" | awk '{print $5}')"
    done

    # Generate .icns from app icon for DMG volume icon
    ICONSET=$(mktemp -d)/Synapty.iconset
    mkdir -p "$ICONSET"
    ICON_SRC="Sources/App/Assets.xcassets/AppIcon.appiconset"
    cp "$ICON_SRC/icon_16x16.png"     "$ICONSET/icon_16x16.png"
    cp "$ICON_SRC/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
    cp "$ICON_SRC/icon_32x32.png"     "$ICONSET/icon_32x32.png"
    cp "$ICON_SRC/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
    cp "$ICON_SRC/icon_128x128.png"   "$ICONSET/icon_128x128.png"
    cp "$ICON_SRC/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
    cp "$ICON_SRC/icon_256x256.png"   "$ICONSET/icon_256x256.png"
    cp "$ICON_SRC/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
    cp "$ICON_SRC/icon_512x512.png"   "$ICONSET/icon_512x512.png"
    cp "$ICON_SRC/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$STAGE/.VolumeIcon.icns"

    # Create read-write DMG, configure installer layout, then compress
    echo "==> Creating installer DMG..."
    hdiutil create -volname "$DMG_NAME" -srcfolder "$STAGE" \
        -ov -format UDRW "zig-out/package/${DMG_NAME}-rw.dmg"

    MOUNT_DIR=$(hdiutil attach "zig-out/package/${DMG_NAME}-rw.dmg" -readwrite \
        | grep '/Volumes/' | awk -F'\t' '{print $NF}')

    # Set volume icon
    SetFile -a C "$MOUNT_DIR"

    hdiutil detach "$MOUNT_DIR"
    hdiutil convert "zig-out/package/${DMG_NAME}-rw.dmg" -format UDZO \
        -o "zig-out/package/${DMG_NAME}.dmg"
    rm -f "zig-out/package/${DMG_NAME}-rw.dmg"
    echo "==> Created: zig-out/package/${DMG_NAME}.dmg"

# Clean build artifacts
clean:
    rm -rf zig-out/ .zig-cache/
    rm -rf ~/Library/Developer/Xcode/DerivedData/Synapty-*
    rm -rf GhosttyKit.xcframework/
    rm -rf Synapty.xcodeproj/
