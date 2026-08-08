# Synapty

Terminal-native orchestration platform for multi-agent systems (Synapse + PTY).
A macOS workbench where AI agents — local or remote, from any provider —
collaborate through a unified PTY substrate: embedded hub, Termius-style host
management, libghostty terminal panes, and a GitHub-Issues task center.

## Install

### Homebrew Cask (recommended)

The app is ad-hoc signed (no Developer ID / notarization yet); installing via
cask removes the quarantine attribute, so it opens without Gatekeeper prompts.

```sh
brew install --cask https://github.com/lucifer1004/synapty/raw/main/cask/synapty.rb
```

### Manual

1. Download `Synapty-<version>.zip` from the [releases page](https://github.com/lucifer1004/synapty/releases).
2. Unzip and drag `Synapty.app` to Applications.
3. First launch: right-click the app → Open (or run
   `xattr -cr /Applications/Synapty.app` in a terminal).

## Build from source

Prerequisites: Xcode, Zig 0.16.x (`brew install zig`), jj (`brew install jj`), xcodegen (`brew install xcodegen`).

```sh
# 1. Fetch the ghostty submodule (pinned upstream commit)
git submodule update --init

# 2. Build GhosttyKit.xcframework (the submodule stays pristine; if your
#    machine lacks the Metal Toolchain component, set SYNAPTY_METAL_DIR —
#    see scripts/build-ghosttykit.sh)
just ghosttykit

# 3. Build and run the app
just app
open ~/Library/Developer/Xcode/DerivedData/Synapty-*/Build/Products/Debug/Synapty.app

# Tests
just test          # zig build test
# Swift tests: xcodebuild -project Synapty.xcodeproj -scheme Synapty -only-testing:SynaptyTests test
```

## Packaging

```sh
just package       # Release app + DMG + zip + sha256 (SYNAPTY_VERSION overrides)
```

## License

MIT — see [LICENSE](LICENSE). The bundled ghostty (submodule) is MIT.
