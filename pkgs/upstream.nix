# Upstream omarchy-apple-dev scripts, for use inside apple-dev:
# - patches/upstream-tools-on-path.patch: the scripts call xtool, ipsw and
#   pymobiledevice3 from PATH (apple-dev puts the Nix packages there) instead
#   of from $HOME/.local/bin and $HOME/pymobile3-venv;
# - patches/ibtool-rn-launchscreen-labels.patch: ibtool compiles React Native's
#   template LaunchScreen.storyboard (label clipsSubviews/minimumFontSize, bold
#   system font, a 1/3 multiplier constraint to the root view); the app shows
#   that storyboard while JS starts. Unverified against Apple goldens, see the patch;
#   the golden self-test still passes;
# - install-toolchain.sh is replaced: Nix builds every piece it installs.
{ stdenvNoCC, src }:

stdenvNoCC.mkDerivation {
  pname = "omarchy-apple-dev";
  version = "unstable-${builtins.substring 0 7 (src.rev or "local")}";
  inherit src;

  patches = [
    ../patches/upstream-tools-on-path.patch
    ../patches/ibtool-rn-launchscreen-labels.patch
  ];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    cp -a . $out
    cat > $out/install-toolchain.sh <<'SH'
    #!/usr/bin/env bash
    echo "nix-apple-dev: Nix builds the toolchain; use apple-dev-setup (or the home-manager module) instead." >&2
    exit 1
    SH
    runHook postInstall
  '';

  # Shell scripts keep their #!/usr/bin/env shebangs: they run in apple-dev.
  dontFixup = true;
}
