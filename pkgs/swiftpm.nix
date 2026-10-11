# Build a SwiftPM package offline with the Swift 6.4 toolchain, inside the
# apple-dev FHS environment (bubblewrap runs nested in the Nix build sandbox).
#
# Dependencies come from a lock file made by scripts/swiftpm-lock.py. They are
# put in SwiftPM's "edited" mode under Packages/ (the way nixpkgs' swiftpm2nix
# vendors), so SwiftPM does no git or network work. Binary artifacts go to
# .build/artifacts, where SwiftPM would download them.
{ lib, stdenvNoCC, fetchFromGitHub, fetchurl, unzip }:

{ pname
, version
, src
, lock                    # path to pkgs/locks/<name>.json
, buildShell              # the FHS env to run swift in (apple-dev-build)
, packagePath ? "."       # the package inside src
, swiftBuildFlags ? [ ]
, installPhase
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
in
stdenvNoCC.mkDerivation (removeAttrs args [ "lock" "buildShell" "packagePath" "swiftBuildFlags" ] // {
  nativeBuildInputs = [ unzip ] ++ (args.nativeBuildInputs or [ ]);

  configurePhase = ''
    runHook preConfigure
    cd ${packagePath}
    export HOME=$TMPDIR/home
    mkdir -p $HOME .build/artifacts Packages
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
    ${buildShell}/bin/apple-dev-build swift build -c release --skip-update \
      ${lib.escapeShellArgs swiftBuildFlags}
    # For installPhase: where this build configuration put its products.
    swiftpmBinPath=$(${buildShell}/bin/apple-dev-build swift build -c release --skip-update \
      ${lib.escapeShellArgs swiftBuildFlags} --show-bin-path)
    runHook postBuild
  '';

  inherit installPhase;

  dontFixup = true;
  passthru = (args.passthru or { }) // { inherit sources; };
})
