# Ubuntu library names the swift.org toolchain links.
# - curses: Ubuntu ships narrow libncurses/libtinfo/libform/libpanel with
#   versioned symbols (NCURSES6_*), and liblldb asks for those versions.
#   NixOS has only the wide build, so build a narrow, versioned ncurses with a
#   separate libtinfo, like Debian does.
# - libedit: Debian numbers the same ABI .so.2; NixOS .so.0. The FHS loader
#   cache indexes by SONAME, so copy the file and set the SONAME.
# - libxml2: 2.14 changed the SONAME to .so.16; 2.13 still is .so.2.
{ runCommand, patchelf, ncurses, libedit, libxml2_13 }:

let
  narrowCurses = (ncurses.override { unicodeSupport = false; }).overrideAttrs (old: {
    pname = "ncurses-narrow-versioned";
    configureFlags = old.configureFlags ++ [ "--with-versioned-syms" "--with-termlib" ];
  });
in
runCommand "apple-dev-compat-libs" { nativeBuildInputs = [ patchelf ]; } ''
  mkdir -p $out/lib
  for l in libncurses libtinfo libform libpanel libmenu; do
    ln -s ${narrowCurses.out}/lib/$l.so.6 $out/lib/$l.so.6
  done
  install -m644 "$(readlink -f ${libedit}/lib/libedit.so.0)" $out/lib/libedit.so.2
  patchelf --set-soname libedit.so.2 $out/lib/libedit.so.2
  ln -s ${libxml2_13.out}/lib/libxml2.so.2 $out/lib/libxml2.so.2
''
