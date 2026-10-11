#!/usr/bin/env python3
"""Make a Nix lock file from a resolved SwiftPM .build/workspace-state.json.

usage: swiftpm-lock.py WORKSPACE_STATE_JSON > pkgs/locks/NAME.json

Run `swift package resolve` in the package first (inside apple-dev). Every
dependency must be a GitHub git package; its hash is the NAR hash of the
GitHub tarball at the pinned revision (what fetchFromGitHub checks).
Binary artifacts keep SwiftPM's own sha256 checksum."""
import json, re, subprocess, sys

state = json.load(open(sys.argv[1]))["object"]
deps = []
for d in state["dependencies"]:
    ref = d["packageRef"]
    if ref["kind"] != "remoteSourceControl":
        sys.exit(f"{ref['identity']}: kind {ref['kind']} is not supported")
    m = re.match(r"https://github\.com/([^/]+)/([^/]+?)(\.git)?/?$", ref["location"])
    if not m:
        sys.exit(f"{ref['identity']}: not a GitHub URL: {ref['location']}")
    rev = d["state"]["checkoutState"]["revision"]
    out = subprocess.run(["nix", "flake", "prefetch", "--json", f"github:{m[1]}/{m[2]}/{rev}"],
                         check=True, capture_output=True, text=True).stdout
    deps.append({"subpath": d["subpath"], "packageRef": ref, "owner": m[1], "repo": m[2],
                 "rev": rev, "hash": json.loads(out)["hash"],
                 "version": d["state"]["checkoutState"].get("version")})
    print(f"  {d['subpath']} {rev[:12]}", file=sys.stderr)
artifacts = []
for a in state.get("artifacts", []):
    src = a["source"]
    if src.get("type") != "remote":
        sys.exit(f"{a['targetName']}: artifact source {src.get('type')} is not supported")
    # The path below .build/artifacts that SwiftPM expects, e.g. xadi/XADIBinary/X.artifactbundle
    rel = a["path"].split("/.build/artifacts/", 1)[1]
    artifacts.append({"packageRef": a["packageRef"], "targetName": a["targetName"], "kind": a["kind"],
                      "url": src["url"], "sha256": src["checksum"], "path": rel})
json.dump({"dependencies": sorted(deps, key=lambda d: d["subpath"]), "artifacts": artifacts},
          sys.stdout, indent=2)
print()
