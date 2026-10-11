# Python 3.13 with pymobiledevice3 and the packages upstream's tools import
# (cryptography), from python/uv.lock. Update: edit python/pyproject.toml,
# then `uv lock` in python/.
{ lib, callPackage, python313, pyproject-nix, uv2nix, pyproject-build-systems }:

let
  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ../python; };

  overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

  # sdists that do not declare their build system
  buildSystemOverrides = final: prev: {
    lzfse = prev.lzfse.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or [ ])
        ++ final.resolveBuildSystem { setuptools = [ ]; };
    });
  };

  pythonSet = (callPackage pyproject-nix.build.packages { python = python313; }).overrideScope
    (lib.composeManyExtensions [
      pyproject-build-systems.overlays.wheel
      overlay
      buildSystemOverrides
    ]);
in
pythonSet.mkVirtualEnv "apple-dev-python" workspace.deps.default
