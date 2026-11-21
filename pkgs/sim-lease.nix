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
    simslim
  ];
  text = builtins.readFile ./sim-lease.sh;

  meta = {
    description = "Lease a fixed pool of slim iOS simulators with a machine-wide boot cap";
    license = lib.licenses.mit;
    mainProgram = "sim-lease";
    platforms = lib.platforms.darwin;
  };
}
