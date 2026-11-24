#!/usr/bin/env bash
# Runs the sim-lease tests straight from a checkout, on Linux or macOS, without
# building the Nix package: it assembles the same script the package wraps,
# with simslim replaced by a stub that forwards to the test's fake ($FAKE_SIMSLIM).
# Needs bash, coreutils, util-linux (flock) and jq; runs shellcheck if present.
#
#   bash tests/sim-lease-local.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/simslim" <<'SH'
#!/usr/bin/env bash
exec "${FAKE_SIMSLIM:?simslim is not stubbed in this test}" "$@"
SH
# The xcrun/simctl guard shims, next to sim-lease as in the package's bin.
{
  printf '#!/usr/bin/env bash\n# sim-lease-guard: shim for xcrun and simctl\nJQ=jq\n'
  cat "$ROOT/pkgs/sim-lease-guard.sh"
} >"$TMP/sim-lease-guard"
ln -s sim-lease-guard "$TMP/xcrun"
ln -s sim-lease-guard "$TMP/simctl"
{
  printf '#!/usr/bin/env bash\nset -o errexit -o nounset -o pipefail\n'
  printf 'SIMSLIM=%q\nreadonly SIMSLIM\n' "$TMP/simslim"
  printf 'GUARD_DIR=%q\n' "$TMP"
  cat "$ROOT/pkgs/sim-lease.sh"
} >"$TMP/sim-lease"
chmod +x "$TMP/simslim" "$TMP/sim-lease" "$TMP/sim-lease-guard"

if command -v shellcheck >/dev/null; then
  shellcheck "$TMP/sim-lease" "$TMP/sim-lease-guard" "$ROOT"/tests/sim-lease-*.sh
  echo 'shellcheck: PASS'
else
  echo 'shellcheck: not installed, skipped'
fi

for test in protected devices recovery guard; do
  bash "$ROOT/tests/sim-lease-$test.sh" "$TMP/sim-lease"
done
