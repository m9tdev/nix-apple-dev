{
  lib,
  writeShellApplication,
  coreutils,
  util-linux,
  jq,
  simslim,
}:

writeShellApplication {
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
    ${builtins.readFile ./sim-lease.sh}
  '';

  meta = {
    description = "Lease a fixed pool of slim iOS simulators with a machine-wide boot cap";
    license = lib.licenses.mit;
    mainProgram = "sim-lease";
    platforms = lib.platforms.darwin;
  };
}
