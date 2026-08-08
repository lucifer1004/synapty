cask "synapty" do
  version "0.1.0"
  # Fill in the sha256 of the released zip (output of `just package`):
  #   shasum -a 256 Synapty-<version>.zip
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/lucifer1004/synapty/releases/download/v#{version}/Synapty-#{version}.zip"
  name "Synapty"
  desc "Terminal-native orchestration platform for multi-agent systems"
  homepage "https://github.com/lucifer1004/synapty"

  # The app is ad-hoc signed (no Developer ID / notarization); the cask
  # installs it with the quarantine attribute removed, so it opens without
  # Gatekeeper warnings.
  app "Synapty.app"

  zap trash: [
    "~/.config/synapty",
    "~/.synapty",
  ]
end
