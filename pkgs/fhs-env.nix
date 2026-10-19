# An FHS environment with Swift 6.4 first on PATH. The toolchain and the tools
# are ordinary Nix binaries; this environment only supplies the fixed /usr/bin
# and /bin paths that SwiftBuild and upstream's scripts call.
#   NAME                 interactive shell
#   NAME CMD ARGS...     run one command
{
  lib,
  callPackage,
  buildFHSEnv,
  writeShellScript,
  writeShellScriptBin,
  swift,
}:

{
  name,
  tools ? [ ],
  profile ? "",
}:

let
  # libheif 1.16 renamed heif-convert to heif-dec (same arguments); Arch still
  # ships the old name, and upstream's AssetKit calls it for HEIC images.
  heifConvert = writeShellScriptBin "heif-convert" ''exec heif-dec "$@"'';
in
buildFHSEnv {
  inherit name;
  # SwiftBuild runs some tools by fixed FHS path (/usr/bin/touch is compiled
  # in; /bin/cp, /bin/chmod, /usr/bin/sed … are in its specs), and upstream's
  # scripts expect a usual Linux userland. The toolchain and the tools do not
  # need this environment for their libraries any more.
  targetPkgs =
    pkgs:
    with pkgs;
    [
      # / is the sysroot for host (Linux) Swift: package manifests, `swift run`
      glibc
      gcc.cc # crtbeginS.o, libgcc
      gcc.cc.lib
      coreutils
      findutils
      gnused
      gnugrep
      gawk
      diffutils
      patch
      file
      which
      util-linux
      gnutar
      gzip
      xz
      bzip2
      zstd
      zip
      unzip
      rsync
      git
      curl
      cacert
      openssl
      libiconv
      gnumake
      cmake
      pkg-config
      # ship.sh, actool (PDF and HEIC images), sdk-free (apfs-fuse)
      poppler-utils
      libheif.bin
      heifConvert
      fuse3
    ]
    ++ tools;

  extraOutputsToInstall = [ "dev" ];

  profile = ''
    export PATH=${swift}/usr/bin:$PATH
    export SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
    # bubblewrap shows root-owned /home and /tmp as owned by nobody, and @swc/core
    # (React Native / One bundlers) refuses to unpack its native addon below them.
    # The sandbox root is ours: give it a cache there.
    if [ -z "''${SWC_NATIVE_BINDING_CACHE:-}" ] && mkdir -p /.apple-dev-cache/swc 2>/dev/null; then
      export SWC_NATIVE_BINDING_CACHE=/.apple-dev-cache/swc
    fi
  ''
  + profile;

  runScript = writeShellScript "${name}-run" ''
    if [ $# -eq 0 ]; then exec bash -l; fi
    exec "$@"
  '';
}
