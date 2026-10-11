# Build a SwiftPM package offline with nixpkgs' Swift.
#
# Dependencies come from a lock file made by scripts/swiftpm-lock.py. They are
# put in SwiftPM's "edited" mode under Packages/ (the way nixpkgs' swiftpm2nix
# vendors), so SwiftPM does no git or network work. Binary artifacts go to
# .build/artifacts, where SwiftPM would download them.
#
# The tools built here (xtool, the macro server, actool) are host tools: they
# do not need the Swift 6.4 toolchain that apps are built with, so they are
# ordinary Nix binaries that run without the FHS environment.
{ lib, swiftPackages, fetchFromGitHub, fetchurl, unzip, pkg-config }:

{ pname
, version
, src
, lock                    # path to pkgs/locks/<name>.json
, product                 # the SwiftPM product to build and install
, packagePath ? "."       # the package inside src
, swiftBuildFlags ? [ ]
, systemLibraries ? [ ]   # C libraries for `.systemLibrary` targets
, ...
}@args:

let
  locked = lib.importJSON lock;

  sources = map (d: d // {
    src = fetchFromGitHub { inherit (d) owner repo rev hash; };
  }) locked.dependencies;

  artifacts = map (a: a // {
    zip = fetchurl { inherit (a) url sha256; };
  }) locked.artifacts;

  stateTemplate = builtins.toFile "workspace-state.json" (builtins.toJSON {
    version = 7;
    object = {
      prebuilts = [ ];
      dependencies = map (d: {
        basedOn = null;
        inherit (d) packageRef subpath;
        state = { name = "edited"; path = null; };
      }) locked.dependencies;
      # "@BUILD@" becomes the absolute .build path at build time.
      artifacts = map (a: {
        inherit (a) packageRef targetName kind;
        path = "@BUILD@/artifacts/${a.path}";
        source = { type = "remote"; url = a.url; checksum = a.sha256; };
      }) locked.artifacts;
    };
  });

  # `.systemLibrary` targets without pkg-config include <header.h> from the
  # system include path; NixOS has none, so name the paths.
  flags = [ "-c" "release" "--product" product ]
    ++ lib.concatMap (p: [
      "-Xcc" "-isystem" "-Xcc" "${lib.getDev p}/include"
      "-Xlinker" "-L${lib.getLib p}/lib"
    ]) systemLibraries
    ++ swiftBuildFlags;
in
swiftPackages.stdenv.mkDerivation (removeAttrs args [ "lock" "product" "packagePath" "swiftBuildFlags" "systemLibraries" ] // {
  nativeBuildInputs = [ swiftPackages.swift swiftPackages.swiftpm unzip pkg-config ]
    ++ (args.nativeBuildInputs or [ ]);
  buildInputs = systemLibraries ++ (args.buildInputs or [ ]);

  configurePhase = ''
    runHook preConfigure
    cd ${packagePath}
    mkdir -p .build/artifacts Packages
    ${lib.concatMapStrings (d: ''
      ln -s ${d.src} Packages/${d.subpath}
    '') sources}
    ${lib.concatMapStrings (a: ''
      mkdir -p ".build/artifacts/$(dirname ${a.path})"
      unzip -q ${a.zip} -d ".build/artifacts/$(dirname ${a.path})"
      test -e ".build/artifacts/${a.path}"
    '') artifacts}
    sed "s|@BUILD@|$PWD/.build|g" ${stateTemplate} > .build/workspace-state.json
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    swift build ${lib.escapeShellArgs flags}
    runHook postBuild
  '';

  # The product, and what it loads from its own directory at run time
  # (shared libraries, resource bundles).
  installPhase = ''
    runHook preInstall
    bin=$(swift build ${lib.escapeShellArgs flags} --show-bin-path)
    mkdir -p $out/libexec/${product} $out/bin
    cp -a "$bin/${product}" $out/libexec/${product}/
    for f in "$bin"/*.so "$bin"/*.resources; do
      [ -e "$f" ] && cp -a "$f" $out/libexec/${product}/
    done
    ln -s $out/libexec/${product}/${product} $out/bin/${product}
    runHook postInstall
  '';

  passthru = (args.passthru or { }) // { inherit sources; };
  meta = { mainProgram = product; platforms = lib.platforms.linux; } // (args.meta or { });
})
