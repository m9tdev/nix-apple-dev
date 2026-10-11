# The tools upstream's installer builds with SwiftPM in $HOME, built by Nix
# instead (same pinned revisions as upstream install-toolchain.sh).
{ lib, fetchFromGitHub, mkSwiftPM, buildShell, upstream }:

let
  # Copy a SwiftPM release product and what it loads at run time (shared
  # libraries and resource bundles next to it; it finds them by $ORIGIN).
  installProduct = product: ''
    runHook preInstall
    bin=$swiftpmBinPath
    mkdir -p $out/libexec/${product} $out/bin
    cp -a "$bin/${product}" $out/libexec/${product}/
    for f in "$bin"/*.so "$bin"/*.resources; do
      [ -e "$f" ] && cp -a "$f" $out/libexec/${product}/
    done
    ln -s $out/libexec/${product}/${product} $out/bin/${product}
    runHook postInstall
  '';
in
{
  # xtool 1.20.1 plus upstream's unreleased fixes (install-toolchain.sh XTOOL_SHA).
  xtool = mkSwiftPM {
    pname = "xtool";
    version = "1.20.1-unstable-f0a1f90";
    src = fetchFromGitHub {
      owner = "joshuaswarren";
      repo = "xtool";
      rev = "f0a1f90efdbb0dc023e276ff529da92618da7a87";
      hash = "sha256-eX262Vjsvez+kqZFIA2UFopmJjwNquMZfZ0fX2bw7lY=";
    };
    lock = ./locks/xtool.json;
    inherit buildShell;
    # `xtool sdk build` without network: local toolset and macro server
    patches = [ ../patches/xtool-offline-sdk-build.patch ];
    swiftBuildFlags = [ "--product" "xtool" ];
    installPhase = installProduct "xtool";
    meta.mainProgram = "xtool";
  };

  # The Darwin macro plugin server with SwiftData and #Preview macros
  # (install-toolchain.sh OAM_SHA).
  open-apple-macros = mkSwiftPM {
    pname = "open-apple-macros-server";
    version = "unstable-cb003a1";
    src = fetchFromGitHub {
      owner = "joshuaswarren";
      repo = "OpenAppleMacros";
      rev = "cb003a1763b08947dd37376ed8240cbfb4745c32";
      hash = "sha256-2a3jhdvpHNKtzIC5mTjD5pRxV1r9wA/7RD8GfnDLEZE=";
    };
    lock = ./locks/oam.json;
    inherit buildShell;
    swiftBuildFlags = [ "--build-system" "native" "--static-swift-stdlib" "--product" "OpenAppleMacrosServer" ];
    installPhase = installProduct "OpenAppleMacrosServer";
    meta.mainProgram = "OpenAppleMacrosServer";
  };

  # Linux actool (asset catalogs) from upstream tools/darwin-tools.
  actool = mkSwiftPM {
    pname = "actool";
    version = "unstable-${builtins.substring 0 7 (upstream.rev or "upstream")}";
    src = upstream;
    packagePath = "tools/darwin-tools";
    lock = ./locks/darwin-tools.json;
    inherit buildShell;
    swiftBuildFlags = [ "--product" "actool" ];
    installPhase = installProduct "actool";
    meta.mainProgram = "actool";
  };
}
