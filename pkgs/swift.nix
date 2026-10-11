# The swift.org 6.4.0 toolchain for Ubuntu 24.04, unchanged except for the
# SwiftBuild spec defaults (patches/swift-strings-encoding-defaults.patch:
# SwiftBuild cannot re-encode .strings files outside Darwin, so the encodings
# must be named; upstream install-toolchain.sh edits a writable toolchain). It runs inside the apple-dev FHS environment,
# which supplies the Ubuntu library names, so nothing is patchelf'd.
{ lib, stdenvNoCC, fetchurl }:

stdenvNoCC.mkDerivation {
  pname = "swift";
  version = "6.4.0";

  src = fetchurl {
    url = "https://download.swift.org/swift-6.4.0-release/ubuntu2404/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE-ubuntu24.04.tar.gz";
    hash = "sha256-afeytNvOYJC2ySGUtxFJoFfhYmkJO1qd3tOK/EoFCU4=";
  };

  patches = [ ../patches/swift-strings-encoding-defaults.patch ];

  # Keep the usr/ level: SwiftPM finds the toolchain by walking up from the
  # binary to usr/lib/swift (upstream docs/DISTROS.md).
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -a usr $out/
    runHook postInstall
  '';

  # Prebuilt binaries for an FHS system: no strip, no patchelf, no shebang rewrite.
  dontFixup = true;

  meta = {
    description = "Swift toolchain from swift.org (Ubuntu 24.04 build), for the apple-dev FHS environment";
    homepage = "https://swift.org";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
  };
}
