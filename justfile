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

# Build macOS GUI app (requires xcgen + ghosttykit first)
app: xcgen
    xcodebuild -project Synapty.xcodeproj -scheme Synapty -configuration Debug -destination 'platform=macOS' build

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

# Enter dev environment
dev:
    devenv shell

# Clean build artifacts
clean:
    rm -rf zig-out/ .zig-cache/
    rm -rf ~/Library/Developer/Xcode/DerivedData/Synapty-*
    rm -rf GhosttyKit.xcframework/
    rm -rf Synapty.xcodeproj/
