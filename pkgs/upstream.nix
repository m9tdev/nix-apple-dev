# Upstream omarchy-apple-dev, wired to the Nix-built tools:
# - every hard-coded $HOME/.local/bin/{xtool,ipsw,rcodesign} and
#   $HOME/pymobile3-venv path points into the Nix store;
# - install-toolchain.sh no longer builds or downloads xtool, OpenAppleMacros,
#   actool, rcodesign, ipsw or the pymobiledevice3 venv. It still builds and
#   registers the iOS SDK from Xcode.xip and installs the SDK-side tools.
# Each patch must match exactly (patch-upstream.py fails loudly), so an
# upstream change shows up as a build error, not as a silent no-op.
{ stdenvNoCC, python3, src, xtool, open-apple-macros, actool, ipsw, rcodesign, python-env }:

stdenvNoCC.mkDerivation {
  pname = "omarchy-apple-dev";
  version = "unstable-${builtins.substring 0 7 (src.rev or "local")}";
  inherit src;

  nativeBuildInputs = [ python3 ];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    cp -a . $out
    chmod -R u+w $out
    python3 ${./patch-upstream.py} $out \
      xtool=${xtool}/bin/xtool \
      oam=${open-apple-macros}/bin/OpenAppleMacrosServer \
      actool=${actool}/bin/actool \
      ipsw=${ipsw}/bin/ipsw ipsw_version=${ipsw.version} \
      rcodesign=${rcodesign}/bin/rcodesign rcodesign_version=${rcodesign.version} \
      python_env=${python-env}
    runHook postInstall
  '';

  # Shell scripts keep their #!/usr/bin/env shebangs: they run in apple-dev.
  dontFixup = true;
}
