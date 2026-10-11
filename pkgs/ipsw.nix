# ipsw from source: the nixpkgs package (3.1.673), updated. 3.1.673's
# developer-portal login (`ipsw download dev`, the Xcode download) fails since
# Apple changed the sign-in page; 3.1.736 works (checked 2026-10-11).
#
# proxyVendor: two files behind the `sandbox` build tag import ipsw's
# closed-source pkg/sandbox (not in git). A normal build does not compile them,
# but `go mod vendor` resolves the imports of every build tag and fails;
# `go mod download` (proxyVendor) does not. Upstream's release config notes
# the same problem with `go mod tidy`.
{
  lib,
  fetchFromGitHub,
  buildGoModule,
}:

buildGoModule (finalAttrs: {
  pname = "ipsw";
  version = "3.1.736";

  src = fetchFromGitHub {
    owner = "blacktop";
    repo = "ipsw";
    tag = "v${finalAttrs.version}";
    hash = "sha256-HTPGSycl1HAGqxHZWPwJ5l518/57i0qI5O5NMuvEyxw=";
  };

  proxyVendor = true;
  vendorHash = "sha256-zj9iBRWjYdX2uZ2r9ebe4oUT89hTfO8RICEPK05Vpeo=";

  ldflags = [
    "-s"
    "-w"
    "-X github.com/blacktop/ipsw/cmd/ipsw/cmd.AppVersion=${finalAttrs.version}"
    "-X github.com/blacktop/ipsw/cmd/ipsw/cmd.AppBuildCommit=${finalAttrs.src.tag}"
  ];

  subPackages = [ "cmd/ipsw" ];

  meta = {
    description = "iOS/macOS Research Swiss Army Knife";
    homepage = "https://blacktop.github.io/ipsw";
    license = lib.licenses.mit;
    mainProgram = "ipsw";
  };
})
