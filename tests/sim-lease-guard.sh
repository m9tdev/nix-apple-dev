#!/usr/bin/env bash
# Guard tests for sim-lease: the xcrun/simctl shims shipped next to sim-lease
# must refuse simctl calls on a leased pool sim from anyone but its lease, and
# refuse the ambiguous `booted` and `all` targets while a lease is live. The
# lease holder itself, sim-lease's own calls, and other simulators are not
# affected. Runs against a stateful fake xcrun, simslim and plutil.
#
# The main case: a helper outside the lease (for example one whose own lease
# is still queued, or one that read a stale UDID left by an earlier lease)
# runs simctl on a UDID that another lease holds. It must fail loudly.
#
# The shims are expected next to sim-lease (bin/xcrun, bin/simctl).
# The sim-lease under test must call simslim through $FAKE_SIMSLIM; see
# tests/sim-lease-local.sh, or the flake's sim-lease-guard check.
# Commands for the leased sim expand $SIM_UDID themselves.
# shellcheck disable=SC2016
set -euo pipefail

SIM_LEASE=${1:?usage: sim-lease-guard.sh /path/to/sim-lease}
GUARD=$(cd "$(dirname "$SIM_LEASE")" && pwd)
GBO=EDD04C40-B5A6-4135-A2BB-19444D4E00B4
DUO_BASE=E1C0D127-94F5-4FF6-B9D8-400507B67947
IPHONE_1=11111111-1111-4111-8111-111111111111
IPHONE_2=22222222-2222-4222-8222-222222222222
OTHER=33333333-3333-4333-8333-333333333333
TMP=$(mktemp -d)
LEASE_PID=
HOLDER=
cleanup() {
  touch "$TMP/go" 2>/dev/null || true
  [[ -z $HOLDER ]] || kill "$HOLDER" 2>/dev/null || true
  if [[ -n $LEASE_PID ]]; then
    kill "$LEASE_PID" 2>/dev/null || true
    wait "$LEASE_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/fake/apps" "$TMP/fake/slim"
export SIM_LEASE_PREFIX=pool-test-
export SIM_LEASE_STATE_DIR=$TMP/state
export SIM_LEASE_POLL_INTERVAL=0.2
unset SIM_LEASE_POOL_SIZE SIM_LEASE_DUO_POOL_SIZE SIM_LEASE_DEVICE_TYPE SIM_LEASE_RUNTIME
unset SIM_LEASE_MAX_BOOTED SIM_LEASE_PROTECTED_UDIDS SIM_LEASE_TOKEN SIM_UDID
export XCRUN_TRACE=$TMP/trace
export FAKE=$TMP/fake
export FAKE_DEVICES=$FAKE/devices.json
export FAKE_PROTECTED="$GBO $DUO_BASE"
export FAKE_SIMSLIM=$TMP/bin/simslim

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x $GUARD/xcrun && -x $GUARD/simctl ]] || fail "no xcrun/simctl guard shims next to $SIM_LEASE"

cat >"$TMP/bin/fake-lib" <<'SH'
exec 7>>"$FAKE/devices.lock"
flock 7
touch_udid() {
  local p
  for p in $FAKE_PROTECTED; do
    if [[ ${1^^} == "$p" ]]; then
      echo "$0 $*" >>"$FAKE/violations"
      echo "fake: refusing to touch protected $1" >&2
      exit 98
    fi
  done
}
get_state() {
  jq -r --arg u "$1" '[.devices[][] | select(.udid == $u or .name == $u) | .state][0] // "missing"' "$FAKE_DEVICES"
}
set_state() {
  jq --arg u "$1" --arg s "$2" \
    '.devices |= map_values(map(if .udid == $u or .name == $u then .state = $s else . end))' \
    "$FAKE_DEVICES" >"$FAKE_DEVICES.tmp"
  mv "$FAKE_DEVICES.tmp" "$FAKE_DEVICES"
}
SH

# The real xcrun stand-in. Any device operation that reaches it is recorded in
# the trace; `booted` and `all` succeed, so a guard that misses them fails the test.
cat >"$TMP/bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$XCRUN_TRACE"
# shellcheck source=/dev/null
source "$(dirname "$0")/fake-lib"
case "$*" in
  '--show-sdk-path')
    echo /fake/sdk
    exit 0
    ;;
  'simctl list devicetypes --json')
    echo '{"devicetypes":[{"name":"iPhone 17","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"}]}'
    exit 0
    ;;
  'simctl list runtimes --json')
    echo '{"runtimes":[{"isAvailable":true,"platform":"iOS","version":"27.2","name":"iOS 27.2","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2","supportedDeviceTypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"}]}]}'
    exit 0
    ;;
  'simctl list devices --json')
    cat "$FAKE_DEVICES"
    exit 0
    ;;
  'simctl list devices booted --json')
    jq '.devices |= map_values(map(select(.state == "Booted")))' "$FAKE_DEVICES"
    exit 0
    ;;
esac
[[ $1 == simctl && $# -ge 3 ]] || { echo "unexpected xcrun $*" >&2; exit 99; }
udid=$3
[[ $udid == booted || $udid == all ]] && exit 0
touch_udid "$udid"
case $2 in
  boot) set_state "$udid" Booted ;;
  shutdown) set_state "$udid" Shutdown ;;
  bootstatus) [[ $(get_state "$udid") == Booted ]] || set_state "$udid" Booted ;;
  listapps)
    jq -Rn '[inputs | {key: ., value: {}}] | from_entries + {"com.apple.mobilesafari": {}}' \
      "$FAKE/apps/$udid" 2>/dev/null || echo '{"com.apple.mobilesafari": {}}'
    ;;
  install) basename "$4" .app >>"$FAKE/apps/$udid" ;;
  uninstall)
    grep -vxF -- "$4" "$FAKE/apps/$udid" >"$FAKE/apps/$udid.tmp" || true
    mv "$FAKE/apps/$udid.tmp" "$FAKE/apps/$udid"
    ;;
  keychain | io | launch | openurl | terminate | spawn) ;;
  *)
    echo "unexpected xcrun $*" >&2
    exit 99
    ;;
esac
SH

cat >"$TMP/bin/plutil" <<'SH'
#!/usr/bin/env bash
cat "${!#}"
SH

cat >"$TMP/bin/simslim" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'simslim %s\n' "$*" >>"$XCRUN_TRACE"
case $1 in
  verify) exit 0 ;;
  *) echo "unexpected simslim $*" >&2; exit 99 ;;
esac
SH
chmod +x "$TMP/bin/xcrun" "$TMP/bin/plutil" "$TMP/bin/simslim"
# The fake is the "real" xcrun; the guard goes in front only where a test says so.
export PATH=$TMP/bin:$PATH
GUARDED_PATH=$GUARD:$PATH

jq -n --arg i1 "$IPHONE_1" --arg i2 "$IPHONE_2" --arg gbo "$GBO" --arg base "$DUO_BASE" \
  --arg other "$OTHER" '
  {devices: {
    "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
      {name: "pool-test-iphone-1", udid: $i1, state: "Shutdown", isAvailable: true,
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
      {name: "pool-test-iphone-2", udid: $i2, state: "Shutdown", isAvailable: true,
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
      {name: "GBO Wallet VM-test", udid: $gbo, state: "Shutdown", isAvailable: true,
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
      {name: "iPhone Duo", udid: $base, state: "Shutdown", isAvailable: true,
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"},
      {name: "My own iPhone", udid: $other, state: "Shutdown", isAvailable: true,
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17"}]
  }}' >"$FAKE_DEVICES"
: >"$FAKE/apps/$IPHONE_1"
: >"$FAKE/apps/$IPHONE_2"
: >"$XCRUN_TRACE"

state_of() {
  jq -r --arg u "$1" '[.devices[][] | select(.udid == $u) | .state][0]' "$FAKE_DEVICES"
}

# outside CMD...: run CMD as a session outside any lease, with the guard first
# on PATH (as an installed sim-lease puts it). Sets OUT and RC.
outside() {
  set +e
  OUT=$(env -u SIM_LEASE_TOKEN PATH="$GUARDED_PATH" "$@" 2>&1)
  RC=$?
  set -e
}

# expect_refused WHAT: the last outside call failed loudly and reached nothing.
expect_refused() {
  [[ $RC -ne 0 ]] || fail "$1 was not refused: $OUT"
  grep -q 'sim-lease-guard: refusing' <<<"$OUT" || fail "$1: no clear refusal message: $OUT"
}

no_foreign_mutation() {
  # Nothing else touches the sim while it is leased: any non-list call on it is foreign.
  if grep -vE '^simctl list ' "$XCRUN_TRACE" |
    grep -Eiq "$IPHONE_1|pool-test-iphone-1| (booted|all)( |\$)"; then
    fail "an outside call reached the leased sim: $(cat "$XCRUN_TRACE")"
  fi
}

# 1. A lease holds pool-test-iphone-1. sim-lease itself runs with the guard
#    first on PATH, as on a host where the package is installed in the profile.
#    The holder's own simctl calls on $SIM_UDID work.
PATH=$GUARDED_PATH "$SIM_LEASE" run -- sh -c '
  rc=0
  [ "$(sed -n 2p "$(command -v xcrun)")" = "# sim-lease-guard: shim for xcrun and simctl" ] || rc=10
  xcrun simctl install "$SIM_UDID" /tmp/Holder.app || rc=11
  xcrun simctl launch "$SIM_UDID" com.example.holder || rc=12
  simctl io "$SIM_UDID" screenshot /dev/null || rc=13
  echo "$rc" >"'"$TMP"'/holder-rc"
  echo "$SIM_UDID" >"'"$TMP"'/ready"
  while [ ! -e "'"$TMP"'/go" ]; do sleep 0.1; done' >"$TMP/lease.out" 2>&1 &
LEASE_PID=$!
for _ in $(seq 100); do
  [[ -e $TMP/ready ]] && break
  kill -0 "$LEASE_PID" 2>/dev/null || fail "the lease ended early: $(cat "$TMP/lease.out")"
  sleep 0.1
done
[[ -e $TMP/ready ]] || fail "the lease did not start: $(cat "$TMP/lease.out")"
[[ $(cat "$TMP/ready") == "$IPHONE_1" ]] || fail "unexpected leased sim $(cat "$TMP/ready")"
[[ $(cat "$TMP/holder-rc") == 0 ]] || fail "the lease holder's own simctl calls failed (code $(cat "$TMP/holder-rc")): $(cat "$TMP/lease.out")"
grep -q '^Holder$' "$FAKE/apps/$IPHONE_1" || fail "the holder's install did not reach the sim"
: >"$XCRUN_TRACE"

# 2. The main case: a helper whose own lease is still queued, or which read a
#    stale UDID from a file left by an earlier lease, targets the leased sim.
echo "$IPHONE_1" >"$TMP/stale-udid"
outside sh -c 'xcrun simctl install "$(cat "$1")" /tmp/Other.app' sh "$TMP/stale-udid"
expect_refused 'xcrun simctl install on a stale UDID'
grep -q "$IPHONE_1" <<<"$OUT" || fail "the refusal does not name the UDID: $OUT"
grep -q 'pool-test-iphone-1' <<<"$OUT" || fail "the refusal does not name the pool sim: $OUT"
outside env SIM_UDID="$IPHONE_1" sh -c 'xcrun simctl io "$SIM_UDID" sendkey 0'
expect_refused 'a stale SIM_UDID'
outside xcrun simctl launch "${IPHONE_1,,}" com.example.other
expect_refused 'a lower-case UDID'
outside simctl openurl "$IPHONE_1" 'myapp://perf-monitor'
expect_refused 'the simctl shim'
outside xcrun --sdk iphonesimulator simctl terminate "$IPHONE_1" com.example.holder
expect_refused 'xcrun --sdk ... simctl'
outside xcrun -r simctl shutdown "$IPHONE_1"
expect_refused 'xcrun -r simctl'
outside xcrun simctl install pool-test-iphone-1 /tmp/Other.app
expect_refused 'the pool sim by name'
# A token from an earlier lease does not open a later one.
outside env SIM_LEASE_TOKEN=0123456789abcdef0123456789abcdef xcrun simctl install "$IPHONE_1" /tmp/Other.app
expect_refused 'a stale lease token'
no_foreign_mutation
[[ $(state_of "$IPHONE_1") == Booted ]] || fail "an outside call changed the leased sim"
grep -q '^Other$' "$FAKE/apps/$IPHONE_1" && fail "an outside install reached the leased sim"

# 3. `booted` and `all` are refused while a lease is live: they can resolve to
#    a leased sim. Listing (where `booted` is a filter) is not a target.
outside xcrun simctl io booted screenshot /dev/null
expect_refused 'booted'
outside simctl install booted /tmp/Other.app
expect_refused 'booted through the simctl shim'
outside xcrun simctl shutdown all
expect_refused 'shutdown all'
no_foreign_mutation
outside xcrun simctl list devices booted --json
[[ $RC -eq 0 ]] || fail "listing booted devices was refused: $OUT"

# 4. Other simulators and other xcrun tools pass straight through.
outside xcrun simctl boot "$OTHER"
[[ $RC -eq 0 && $(state_of "$OTHER") == Booted ]] || fail "a non-pool sim was blocked: $OUT"
outside xcrun simctl shutdown "$OTHER"
[[ $RC -eq 0 && $(state_of "$OTHER") == Shutdown ]] || fail "a non-pool sim was blocked: $OUT"
outside xcrun --show-sdk-path
[[ $RC -eq 0 && $OUT == /fake/sdk ]] || fail "xcrun --show-sdk-path did not pass through: $OUT"
# The free pool sim is not leased; the guard does not stand in the way.
outside xcrun simctl listapps "$IPHONE_2"
[[ $RC -eq 0 ]] || fail "an unleased sim was refused: $OUT"
[[ ! -s $FAKE/violations ]] || fail "a protected UDID was touched: $(cat "$FAKE/violations")"

# fake_lease UDID JSON-FIELDS: a live lease record for UDID, held by a sleeper,
# with the given fields (a record made by an older sim-lease has no token).
fake_lease() {
  sleep 60 &
  HOLDER=$!
  jq -n --arg udid "$1" --argjson pid "$HOLDER" "{udid: \$udid, pid: \$pid} + $2" \
    >"$TMP/state/pool-test-/leases/$1"
}
drop_fake_lease() {
  rm -f "$TMP/state/pool-test-/leases/$1"
  kill "$HOLDER" 2>/dev/null || true
  wait "$HOLDER" 2>/dev/null || true
  HOLDER=
}

# 4a. A record with empty fields keeps the others in place (no "since unknown").
fake_lease "$IPHONE_2" '{name: "", state: "running", token: "feedfacefeedfacefeedfacefeedface", started: "2026-01-01T00:00:00Z"}'
outside xcrun simctl listapps "$IPHONE_2"
expect_refused 'a lease record with an empty name'
grep -q "PID $HOLDER since 2026-01-01T00:00:00Z," <<<"$OUT" || fail "fields of a lease record were misread: $OUT"
# 4b. Every device of `pair`, and --udid= values, are checked.
outside xcrun simctl pair "$OTHER" "$IPHONE_2"
expect_refused 'the second device of pair'
outside xcrun simctl io --udid="$IPHONE_2" screenshot /dev/null
expect_refused 'a --udid= value'
drop_fake_lease "$IPHONE_2"

# 4c. A lease made by a sim-lease without the guard has no token. Its holder
#     (and its cleanup) cannot show one, so the guard lets calls on it through.
fake_lease "$IPHONE_2" '{name: "pool-test-iphone-2", state: "running", started: "2026-01-01T00:00:00Z"}'
outside xcrun simctl listapps "$IPHONE_2"
[[ $RC -eq 0 ]] || fail "a lease without a token blocked its own holder: $OUT"
outside simctl keychain pool-test-iphone-2 reset
[[ $RC -eq 0 ]] || fail "a lease without a token blocked its own holder: $OUT"
drop_fake_lease "$IPHONE_2"

# 5. The lease releases cleanly through the guard (its own cleanup is not
#    refused), and reports how many outside calls on its sim were refused.
touch "$TMP/go"
wait "$LEASE_PID" || fail "the lease failed: $(cat "$TMP/lease.out")"
LEASE_PID=
[[ $(state_of "$IPHONE_1") == Shutdown ]] || fail "the lease left its sim $(state_of "$IPHONE_1")"
grep -q "^simctl uninstall $IPHONE_1 Holder" "$XCRUN_TRACE" || fail "release did not wipe the holder's app"
grep -q 'refused 8 simctl calls on this sim from outside the lease' "$TMP/lease.out" ||
  fail "release did not report the refused calls: $(cat "$TMP/lease.out")"
[[ -z $(ls -A "$TMP/state/pool-test-/leases") ]] || fail "lease records left"

# 6. With no live lease, `booted` passes through again (non-pool use); a live
#    lease without a token still makes it ambiguous.
outside xcrun simctl io booted screenshot /dev/null
[[ $RC -eq 0 ]] || fail "booted was refused with no live lease: $OUT"
fake_lease "$IPHONE_2" '{name: "pool-test-iphone-2", state: "running"}'
outside xcrun simctl io booted screenshot /dev/null
expect_refused 'booted while a lease without a token is live'
drop_fake_lease "$IPHONE_2"
[[ ! -s $FAKE/violations ]] || fail "a protected UDID was touched: $(cat "$FAKE/violations")"

echo 'guard test: PASS'
