# The tools upstream's installer builds with SwiftPM in $HOME, built by Nix
# with nixpkgs' Swift instead (same pinned revisions as upstream
# install-toolchain.sh). They run on the host, with or without apple-dev.
{
  fetchFromGitHub,
  mkSwiftPM,
  upstream,
  lib,
  makeWrapper,
  writeShellScriptBin,
  librsvg,
  poppler-utils,
  libheif,
  libimobiledevice,
  libplist,
  libusbmuxd,
  libimobiledevice-glue,
  openssl,
  xz,
  zlib,
  bzip2,
}:

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
    product = "xtool";
    # `xtool sdk build` without network: local toolset and macro server
    patches = [ ../patches/xtool-offline-sdk-build.patch ];
    postPatch = ''
      grep -q XTOOL_TOOLSET_TARBALL Sources/XToolSupport/SDKBuilder.swift
      grep -q XTOOL_OAM_SERVER Sources/XToolSupport/SDKBuilder.swift
    '';
    systemLibraries = [
      libimobiledevice
      libplist
      libusbmuxd
      libimobiledevice-glue
      openssl
      xz
      zlib
      bzip2 # unxip's lzma and zlib targets
    ];
    meta.description = "Cross-platform Xcode replacement (xtool-org/xtool, with omarchy-apple-dev's fixes)";
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
    product = "OpenAppleMacrosServer";
    meta.description = "Macro plugin server for Apple's SwiftUI, SwiftData and #Preview macros";
  };

  # Linux actool (asset catalogs) from upstream tools/darwin-tools.
  actool = mkSwiftPM {
    pname = "actool";
    version = "unstable-${builtins.substring 0 7 (upstream.rev or "upstream")}";
    src = upstream;
    packagePath = "tools/darwin-tools";
    lock = ./locks/darwin-tools.json;
    product = "actool";
    # AssetKit with the macOS Icon Composer layout (m9tdev/AssetKit#1, on top
    # of the omarchy/mac-icon pin): without it macOS shows the generic icon
    # for an .icon app icon. On top of that (a stacked m9tdev/AssetKit PR):
    # app icon sets with empty slots compile, the empty slots are skipped, and
    # actool's warning is printed for an empty required size. Back to
    # upstream's pin once it lands there.
    # patches/actool-app-icon-warnings.patch: passes --target-device to
    # AssetKit and prints its warnings in actool's format.
    patches = [ ../patches/actool-app-icon-warnings.patch ];
    postPatch = ''
      substituteInPlace tools/darwin-tools/Package.swift --replace-fail \
        '.package(url: "https://github.com/joshuaswarren/AssetKit", revision: "705ce2f2b797835cf4bac65e0dff1e9ca37ba0bf")' \
        '.package(url: "https://github.com/m9tdev/AssetKit", revision: "fade9f53dcb956c2706324ebfdb2ba95c2ade3ad")'
    '';
    # AssetKit runs these through PATH: rsvg-convert (SVG, Icon Composer
    # layers), pdfinfo/pdftocairo (PDF), heif-convert (HEIC; libheif 1.16
    # renamed it heif-dec, same arguments).
    nativeBuildInputs = [ makeWrapper ];
    postInstall = ''
      rm $out/bin/actool
      makeWrapper $out/libexec/actool/actool $out/bin/actool --prefix PATH : ${
        lib.makeBinPath [
          librsvg
          poppler-utils
          libheif.bin
          (writeShellScriptBin "heif-convert" ''exec ${libheif.bin}/bin/heif-dec "$@"'')
        ]
      }
    '';
    meta.description = "Asset catalog compiler for Linux (omarchy-apple-dev tools/darwin-tools)";
  };
}
