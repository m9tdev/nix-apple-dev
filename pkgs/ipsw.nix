# ipsw, the upstream release binary (static Go, pinned by hash).
# nixpkgs (2026-10) has 3.1.673, whose developer-portal login (`ipsw download
# dev`, the Xcode download) fails since Apple changed the sign-in page;
# 3.1.736 works (checked 2026-10-11). It cannot be built from source: the code
# imports pkg/sandbox, which upstream keeps out of git (.gitignore).
{ lib, stdenvNoCC, fetchurl }:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "ipsw";
  version = "3.1.736";

  src = fetchurl {
    url = "https://github.com/blacktop/ipsw/releases/download/v${finalAttrs.version}/ipsw_${finalAttrs.version}_linux_x86_64.tar.gz";
    hash = "sha256-Ny1acX2vBE0cMsGH9z3jTg6ueY2tI8a5Wj1Bl9NQ9/o=";
  };

  sourceRoot = ".";
  installPhase = ''
    runHook preInstall
    install -Dm755 ipsw $out/bin/ipsw
    runHook postInstall
  '';

  meta = {
    description = "iOS/macOS Research Swiss Army Knife";
    homepage = "https://blacktop.github.io/ipsw";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "ipsw";
  };
})
