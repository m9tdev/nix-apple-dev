# Upstream omarchy-apple-dev scripts, for use inside apple-dev. The scripts
# fall back to xtool, ipsw and pymobiledevice3 on PATH (apple-dev puts the Nix
# packages there) when $HOME/.local/bin and $HOME/pymobile3-venv don't have
# them. install-toolchain.sh is replaced: Nix builds every piece it installs.
{ stdenvNoCC, src }:

stdenvNoCC.mkDerivation {
  pname = "omarchy-apple-dev";
  version = "unstable-${builtins.substring 0 7 (src.rev or "local")}";
  inherit src;

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
