# simslim: turns off the launchd services an iOS/tvOS/watchOS/visionOS
# simulator does not need, so many more simulators fit on one Mac. Not in
# nixpkgs. CLI only: upstream's SwiftUI app (gui/) is built separately with
# Xcode and is not packaged here.
{
  lib,
  fetchFromGitHub,
  buildGoModule,
}:

buildGoModule (finalAttrs: {
  pname = "simslim";
  version = "0.15.0";

  src = fetchFromGitHub {
    owner = "MobAI-App";
    repo = "simslim";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Cgm7hp3LBw635taWCQZypiDC1i8Qb4WVZL64g2jewwg=";
  };

  vendorHash = "sha256-y6Nbszl+bmjxRII6pryzv31mZN2BpSTuZYmrEVKxqu4=";

  # Upstream's Makefile sets main.version the same way.
  ldflags = [
    "-s"
    "-w"
    "-X main.version=${finalAttrs.src.tag}"
  ];

  subPackages = [ "cmd/simslim" ];

  meta = {
    description = "Run more Apple simulators on one Mac by turning off background services they don't need";
    homepage = "https://github.com/MobAI-App/simslim";
    license = lib.licenses.mit;
    mainProgram = "simslim";
    platforms = lib.platforms.darwin;
  };
})
