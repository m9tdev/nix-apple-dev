# An FHS environment shaped like the Ubuntu 24.04 setup that upstream tested
# (docs/DISTROS.md), with Swift 6.4 first on PATH. Two are made from this:
# apple-dev-build (builds the Nix packages of the tools, in the build sandbox)
# and apple-dev (the user environment, with those tools on PATH).
#   NAME                 interactive shell
#   NAME CMD ARGS...     run one command
{ lib, callPackage, buildFHSEnv, writeShellScript, writeShellScriptBin, swift }:

{ name, tools ? [ ], profile ? "" }:

let
  compat = callPackage ./compat-libs.nix { };

  # libheif 1.16 renamed heif-convert to heif-dec (same arguments); Arch still
  # ships the old name, and upstream's AssetKit calls it for HEIC images.
  heifConvert = writeShellScriptBin "heif-convert" ''exec heif-dec "$@"'';
in
buildFHSEnv {
  inherit name;
  targetPkgs = pkgs: with pkgs; [
    # Swift toolchain runtime and C/C++ build basics
    # gcc.cc: the unwrapped GCC tree (/usr/lib/gcc/<triple>/<ver>: crtbeginS.o,
    # libgcc, libstdc++ headers) that clang finds by FHS layout
    glibc gcc gcc.cc binutils gnumake cmake pkg-config file which
    coreutils findutils gnused gnugrep gawk gnutar gzip xz bzip2 zstd diffutils patch
    git curl cacert openssl zlib libxml2 libedit sqlite libuuid util-linux
    llvm
    # xtool build deps (pkg-config: libimobiledevice-1.0, openssl)
    libimobiledevice libplist libusbmuxd libimobiledevice-glue libtatsu
    # python: venv for pymobiledevice3 (the tailnet tunnel needs 3.13+);
    # lldb from Swift 6.4 links libpython3.12
    python313 python312
    # ship.sh, actool (PDF and HEIC images), sdk-free
    zip unzip rsync poppler-utils libheif libheif.bin heifConvert fuse3
    # nix-ld style libs some pip wheels expect
    stdenv.cc.cc.lib libffi
    # before ncurses: the FHS merge keeps the first file of a name
    compat
  ] ++ tools;

  extraOutputsToInstall = [ "dev" ];

  profile = ''
    export PATH=${swift}/usr/bin:$PATH
    export SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
  '' + profile;

  runScript = writeShellScript "${name}-run" ''
    if [ $# -eq 0 ]; then exec bash -l; fi
    exec "$@"
  '';
}
