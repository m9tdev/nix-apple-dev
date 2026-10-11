# `apple-dev`: an FHS environment shaped like the Ubuntu 24.04 setup that
# upstream tested (docs/DISTROS.md), with Swift 6.4 first on PATH.
#   apple-dev                 interactive shell
#   apple-dev xtool dev run   run one command
# `apple-dev-setup` (in the same package) runs upstream's installer inside it.
{ lib, callPackage, buildFHSEnv, writeShellScript, writeShellScriptBin, symlinkJoin, swift, upstream }:

let
  # The writable copy of upstream: its scripts build tools in-tree
  # (tools/darwin-tools/.build) and find their siblings relative to themselves.
  checkout = "$HOME/.local/share/nix-apple-dev/omarchy-apple-dev";

  compat = callPackage ./compat-libs.nix { };

  # libheif 1.16 renamed heif-convert to heif-dec (same arguments); Arch still
  # ships the old name, and upstream's AssetKit calls it for HEIC images.
  heifConvert = writeShellScriptBin "heif-convert" ''exec heif-dec "$@"'';

  env = buildFHSEnv {
    name = "apple-dev";

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
    ];

    extraOutputsToInstall = [ "dev" ];

    profile = ''
      export PATH=${swift}/usr/bin:$HOME/.local/bin:${checkout}:${checkout}/tools:$PATH
      export APPLE_DEV_UPSTREAM=${checkout}
      export SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
    '';

    runScript = writeShellScript "apple-dev-run" ''
      if [ $# -eq 0 ]; then exec bash -l; fi
      exec "$@"
    '';
  };

  setup = writeShellScriptBin "apple-dev-setup" ''
    set -euo pipefail
    # Sync the writable checkout to the pinned upstream revision.
    dest=${checkout}
    if [ "$(cat "$dest/.nix-apple-dev-src" 2>/dev/null || true)" != "${upstream}" ]; then
      mkdir -p "$dest"
      ${lib.getExe' env "apple-dev"} rsync -a --chmod=u+w ${upstream}/ "$dest/"
      echo "${upstream}" > "$dest/.nix-apple-dev-src"
      echo "upstream synced to $dest"
    fi
    exec ${lib.getExe' env "apple-dev"} "$dest/install-toolchain.sh" --user-only --mode full "$@"
  '';
in
symlinkJoin {
  name = "apple-dev";
  paths = [ env setup ];
  passthru = { inherit env setup swift; };
}
