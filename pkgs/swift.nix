# The swift.org Swift 6.4.0 toolchain (Ubuntu 24.04 build), patched to run as
# an ordinary Nix binary:
# - autoPatchelfHook links it against nixpkgs libraries. Two names differ from
#   Ubuntu: Debian calls libedit's .so.0 ABI .so.2 (replace-needed), and liblldb
#   needs narrow ncurses with versioned symbols (NCURSES6_*), which nixpkgs only
#   builds wide; a narrow, versioned build is made here, as Debian does.
# - Host (Linux) builds: $out/sysroot has glibc, GCC's start files and Swift's
#   own runtime (set SDKROOT=$out/sysroot outside apple-dev; inside, / is the
#   sysroot). Clang config files for the host triple only set the linker and
#   Nix's dynamic linker (Darwin targets use the iOS/macOS SDK).
# - patches/swift-strings-encoding-defaults.patch: SwiftBuild cannot re-encode
#   .strings files outside Darwin, so the encodings must be named (upstream
#   install-toolchain.sh edits a writable toolchain instead).
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  ncurses,
  zlib,
  libxml2_13,
  libedit,
  sqlite,
  curl,
  libuuid,
  python312,
  libffi,
  zstd,
  xz,
  glibc,
}:

let
  triple = "x86_64-unknown-linux-gnu";
  gcc = stdenv.cc.cc;

  narrowCurses = (ncurses.override { unicodeSupport = false; }).overrideAttrs (old: {
    pname = "ncurses-narrow-versioned";
    configureFlags = old.configureFlags ++ [
      "--with-versioned-syms"
      "--with-termlib"
    ];
  });
in
stdenv.mkDerivation {
  pname = "swift";
  version = "6.4.0";

  src = fetchurl {
    url = "https://download.swift.org/swift-6.4.0-release/ubuntu2404/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE-ubuntu24.04.tar.gz";
    hash = "sha256-afeytNvOYJC2ySGUtxFJoFfhYmkJO1qd3tOK/EoFCU4=";
  };

  patches = [ ../patches/swift-strings-encoding-defaults.patch ];

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    gcc.lib
    zlib
    libxml2_13 # libxml2.so.2 (2.14 renamed it .so.16)
    libedit
    narrowCurses
    sqlite
    curl
    libuuid
    python312 # lldb
    libffi
    zstd
    xz
  ];

  # Keep the usr/ level: SwiftPM finds the toolchain by walking up from the
  # binary to usr/lib/swift (upstream docs/DISTROS.md).
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -a usr $out/
    # Same Debug fix as in ios-sdk.nix: clang compiles of Objective-C++ that
    # include a generated -Swift.h find this toolchain's copy of the header.
    substituteInPlace $out/usr/lib/swift/swiftToCxx/_SwiftCxxInteroperability.h \
      --replace-fail '#if defined(DEBUG) && __has_attribute(used)' '#if 0'

    # Host sysroot: what clang and the Swift importer expect under / on Ubuntu.
    sr=$out/sysroot
    mkdir -p $sr/usr/lib/gcc/${triple}
    ln -s ${glibc.dev}/include $sr/usr/include
    for f in ${glibc}/lib/* ${glibc.dev}/lib/*; do ln -sf "$f" $sr/usr/lib/; done
    ln -s ${gcc}/lib/gcc/${triple}/${gcc.version} $sr/usr/lib/gcc/${triple}/${gcc.version}
    ln -sf ${gcc.lib}/lib/libgcc_s.so* $sr/usr/lib/
    ln -s $out/usr/lib/swift $out/usr/lib/swift_static $sr/usr/lib/
    # glibc's linker scripts name absolute /nix/store paths; inside a sysroot
    # the linker would put the sysroot in front of them. Use plain names.
    rm $sr/usr/lib/libc.so $sr/usr/lib/libm.so
    echo 'GROUP ( libc.so.6 libc_nonshared.a AS_NEEDED ( ld-linux-x86-64.so.2 ) )' > $sr/usr/lib/libc.so
    echo 'GROUP ( libm.so.6 AS_NEEDED ( libmvec.so.1 ) )' > $sr/usr/lib/libm.so

    # clang reads <triple>-<driver>.cfg only for that target triple: Linux
    # links use the toolchain's own lld and Nix's dynamic linker. No --sysroot
    # here: Swift passes its SDK to clang (SDKROOT outside apple-dev, / inside),
    # and the two must agree for the Glibc module.
    for driver in clang clang++; do
      cat > $out/usr/bin/${triple}-$driver.cfg <<CFG
    --ld-path=$out/usr/bin/ld.lld
    -Wl,-dynamic-linker,${glibc}/lib/ld-linux-x86-64.so.2
    -Wl,-rpath,${glibc}/lib
    -Wl,-rpath,${gcc.lib}/lib
    CFG
    done
    runHook postInstall
  '';

  preFixup = ''
    # Debian's libedit.so.2 is nixpkgs' libedit.so.0 (same ABI).
    find $out/usr -type f \( -perm -u+x -o -name '*.so*' \) -print0 |
      while IFS= read -r -d "" f; do
        if patchelf --print-needed "$f" 2>/dev/null | grep -qx libedit.so.2; then
          patchelf --replace-needed libedit.so.2 libedit.so.0 "$f"
        fi
      done
  '';

  # libedit pulls in nixpkgs' wide ncurses, and autoPatchelf may pick it for
  # libncurses.so.6; liblldb needs the narrow, versioned build. Replace every
  # wide ncurses entry in the search paths.
  # Run autoPatchelf here, so the fix below comes after it.
  dontAutoPatchelf = true;
  postFixup = ''
    autoPatchelf $out
    find $out/usr -type f \( -perm -u+x -o -name '*.so*' \) -print0 |
      while IFS= read -r -d "" f; do
        rp=$(patchelf --print-rpath "$f" 2>/dev/null) || continue
        new=""; changed=""
        IFS=: read -ra parts <<< "$rp"
        for e in "''${parts[@]}"; do
          if [[ $e == /nix/store/*-ncurses-[0-9]*/lib ]]; then
            e=${narrowCurses.out}/lib; changed=1
          fi
          new=''${new:+$new:}$e
        done
        if [ -n "$changed" ]; then patchelf --set-rpath "$new" "$f"; fi
      done
  '';

  # Stripping would break the Swift runtime libraries' reflection metadata.
  dontStrip = true;
  # Shell/Python scripts in usr/bin keep their shebangs (they use /usr/bin/env).
  dontPatchShebangs = true;

  meta = {
    description = "Swift toolchain from swift.org (Ubuntu 24.04 build), patched for Nix";
    homepage = "https://swift.org";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
  };
}
