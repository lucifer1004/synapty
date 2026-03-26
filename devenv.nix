{ pkgs, lib, inputs, ... }:

{
  packages = [
    pkgs.zig
    pkgs.jujutsu
    pkgs.just
    inputs.govctl.packages.${pkgs.system}.default
  ];

  enterShell = ''
    echo "Synapty dev environment"
    echo "  zig:     $(zig version)"
    echo "  jj:      $(jj --version)"
    echo "  govctl:  $(govctl --version)"
    if ! command -v xcodebuild &> /dev/null; then
      echo "  xcode:   NOT FOUND — install Xcode from the App Store (required for GUI builds)"
    fi
  '';

  enterTest = ''
    zig version | grep "0.15"
    jj --version
    govctl --version
  '';
}
