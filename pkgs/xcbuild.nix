# CocoaPods workspaces (React Native, Expo, One) on Linux:
#   apple-dev-pod        CocoaPods (`pod install`), with Linux stand-ins for xcrun & co.
#   apple-dev-xcbuild    builds the workspace for an iOS device, like xcodebuild
# Both run inside apple-dev (clang, swiftc and the SDK come from there).
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  ruby,
}:

let
  # CocoaPods from the gem set (the top-level `cocoapods` is marked darwin-only;
  # the gem is plain Ruby and runs on Linux). xcodeproj reads the projects.
  rubyEnv = ruby.withPackages (ps: [
    ps.cocoapods
    ps.xcodeproj
  ]);
in
stdenvNoCC.mkDerivation {
  pname = "apple-dev-xcbuild";
  version = "0.1.0";
  src = ../xcbuild;
  nativeBuildInputs = [ makeWrapper ];
  dontPatchShebangs = true; # the stand-ins run inside apple-dev (FHS)
  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec/xcbuild $out/bin
    cp -r . $out/libexec/xcbuild/
    makeWrapper ${python3}/bin/python3 $out/bin/apple-dev-xcbuild \
      --add-flags $out/libexec/xcbuild/xcbuild.py \
      --prefix PATH : $out/libexec/xcbuild/bin \
      --set XCBUILD_RUBY ${rubyEnv}/bin/ruby
    makeWrapper ${rubyEnv}/bin/pod $out/bin/apple-dev-pod \
      --prefix PATH : $out/libexec/xcbuild/bin \
      --set-default LANG C.UTF-8
    runHook postInstall
  '';
  meta = {
    description = "xcodebuild stand-in for CocoaPods workspaces, and CocoaPods, for iOS builds on Linux";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
