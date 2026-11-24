{
  lib,
  writeShellApplication,
  runCommand,
  symlinkJoin,
  bash,
  coreutils,
  util-linux,
  jq,
  simslim,
}:

let
  # The xcrun/simctl shims. They hand everything to the next xcrun on PATH
  # unchanged, except simctl calls on a sim leased to another process. They do
  # not change PATH: jq is called by its store path.
  guard = runCommand "sim-lease-guard" { } ''
    mkdir -p $out/bin $out/libexec
    {
      echo '#!${bash}/bin/bash'
      echo '# sim-lease-guard: shim for xcrun and simctl'
      echo 'JQ=${jq}/bin/jq'
      cat ${./sim-lease-guard.sh}
    } >$out/libexec/sim-lease-guard
    chmod +x $out/libexec/sim-lease-guard
    ln -s ../libexec/sim-lease-guard $out/bin/xcrun
    ln -s ../libexec/sim-lease-guard $out/bin/simctl
  '';

  sim-lease = writeShellApplication {
    name = "sim-lease";
    runtimeInputs = [
      coreutils
      util-linux
      jq
    ];
    # Keep upstream's full CLI off PATH: sim-lease calls only its audited
    # per-UDID operations through this private store-path reference.
    text = ''
      SIMSLIM=${simslim}/bin/simslim
      readonly SIMSLIM
      GUARD_DIR=${guard}/bin
      ${builtins.readFile ./sim-lease.sh}
    '';
  };
in
symlinkJoin {
  name = "sim-lease";
  paths = [
    sim-lease
    guard
  ];

  meta = {
    description = "Lease a fixed pool of slim iOS simulators with a machine-wide boot cap";
    license = lib.licenses.mit;
    mainProgram = "sim-lease";
    platforms = lib.platforms.darwin;
  };
}
