#!/usr/bin/env bash
# Crash-recovery and undo tests for sim-lease, against a stateful fake xcrun,
# simslim and plutil. Covers a run whose connection drops mid-command, the next
# run reclaiming the sim it left booted, never taking a live lease, undo leaving
# a pool sim ready for run, undo --stock, and the protected non-pool UDIDs.
#
# The sim-lease under test must call simslim through $FAKE_SIMSLIM; see
# tests/sim-lease-local.sh, or the flake's sim-lease-recovery check.
# Commands for the leased sim expand $SIM_UDID themselves.
# shellcheck disable=SC2016
set -euo pipefail

SIM_LEASE=${1:?usage: sim-lease-recovery.sh /path/to/sim-lease}
GBO=EDD04C40-B5A6-4135-A2BB-19444D4E00B4
DUO_BASE=E1C0D127-94F5-4FF6-B9D8-400507B67947
IPHONE_1=11111111-1111-4111-8111-111111111111
IPHONE_2=22222222-2222-4222-8222-222222222222
TMP=$(mktemp -d)
HOLDERS=()
cleanup() {
  local pid
  for pid in "${HOLDERS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/fake/apps" "$TMP/fake/slim"
export SIM_LEASE_PREFIX=pool-test-
export SIM_LEASE_STATE_DIR=$TMP/state
export SIM_LEASE_POLL_INTERVAL=0.2
unset SIM_LEASE_POOL_SIZE SIM_LEASE_DUO_POOL_SIZE SIM_LEASE_DEVICE_TYPE SIM_LEASE_RUNTIME
unset SIM_LEASE_MAX_BOOTED SIM_LEASE_PROTECTED_UDIDS
export XCRUN_TRACE=$TMP/trace
export FAKE=$TMP/fake
export FAKE_DEVICES=$FAKE/devices.json
export FAKE_PROTECTED="$GBO $DUO_BASE"
export FAKE_SIMSLIM=$TMP/bin/simslim
LEASES=$TMP/state/pool-test-/leases
LOCKS=$TMP/state/pool-test-/locks

# Shared by the fakes: one lock for the device list, a protected-UDID tripwire.
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
  jq -r --arg u "$1" '[.devices[][] | select(.udid == $u) | .state][0] // "missing"' "$FAKE_DEVICES"
}
set_state() {
  jq --arg u "$1" --arg s "$2" \
    '.devices |= map_values(map(if .udid == $u then .state = $s else . end))' \
    "$FAKE_DEVICES" >"$FAKE_DEVICES.tmp"
  mv "$FAKE_DEVICES.tmp" "$FAKE_DEVICES"
}
need_state() {
  local state
  state=$(get_state "$1")
  if [[ $state != "$2" ]]; then
    echo "fake: unable to $3 device in current state: $state" >&2
    exit 149
  fi
}
SH

cat >"$TMP/bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$XCRUN_TRACE"
# shellcheck source=/dev/null
source "$(dirname "$0")/fake-lib"
case "$*" in
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
touch_udid "$udid"
case $2 in
  boot)
    need_state "$udid" Shutdown boot
    set_state "$udid" Booted
    ;;
  shutdown)
    need_state "$udid" Booted shutdown
    set_state "$udid" Shutdown
    ;;
  bootstatus)
    [[ $(get_state "$udid") == Booted ]] || set_state "$udid" Booted
    ;;
  listapps)
    need_state "$udid" Booted 'list apps on'
    jq -Rn '[inputs | {key: ., value: {}}] | from_entries + {"com.apple.mobilesafari": {}}' \
      "$FAKE/apps/$udid" 2>/dev/null || echo '{"com.apple.mobilesafari": {}}'
    ;;
  uninstall)
    need_state "$udid" Booted 'uninstall from'
    grep -vxF -- "$4" "$FAKE/apps/$udid" >"$FAKE/apps/$udid.tmp" || true
    mv "$FAKE/apps/$udid.tmp" "$FAKE/apps/$udid"
    ;;
  keychain)
    need_state "$udid" Booted 'reset the keychain of'
    ;;
  *)
    echo "unexpected xcrun $*" >&2
    exit 99
    ;;
esac
SH

cat >"$TMP/bin/plutil" <<'SH'
#!/usr/bin/env bash
# plutil -convert json -o - FILE: the fake listapps already prints JSON.
cat "${!#}"
SH

cat >"$TMP/bin/simslim" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'simslim %s\n' "$*" >>"$XCRUN_TRACE"
# shellcheck source=/dev/null
source "$(dirname "$0")/fake-lib"
udid=$2
touch_udid "$udid"
slim=$(cat "$FAKE/slim/$udid" 2>/dev/null || echo 0)
case $1 in
  on | off)
    # Like upstream, on/off boot the simulator and leave it booted.
    [[ $(get_state "$udid") == Booted ]] || set_state "$udid" Booted
    if [[ $1 == on ]]; then echo 1; else echo 0; fi >"$FAKE/slim/$udid"
    ;;
  verify)
    [[ $slim == 1 ]] || { echo "simslim: $udid is not slim" >&2; exit 1; }
    ;;
  status)
    if [[ ${3:-} == --json ]]; then
      echo "{\"managedDisabled\": $((slim * 40))}"
    else
      echo "$((slim * 40))/40 managed launchd labels disabled"
    fi
    ;;
  *)
    echo "unexpected simslim $*" >&2
    exit 99
    ;;
esac
SH
chmod +x "$TMP/bin/xcrun" "$TMP/bin/plutil" "$TMP/bin/simslim"
export PATH=$TMP/bin:$PATH

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# devices STATE_IPHONE_1 STATE_IPHONE_2 [STATE_GBO]: both pool members slim and
# app-free, the protected GBO sim (booted by default: it holds one of the two
# slots) and the protected Duo base sim.
devices() {
  jq -n --arg s1 "$1" --arg s2 "$2" --arg sg "${3:-Booted}" \
    --arg i1 "$IPHONE_1" --arg i2 "$IPHONE_2" --arg gbo "$GBO" --arg base "$DUO_BASE" '
    {devices: {
      "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
        {name: "pool-test-iphone-1", udid: $i1, state: $s1, isAvailable: true,
          deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
        {name: "pool-test-iphone-2", udid: $i2, state: $s2, isAvailable: true,
          deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
        {name: "GBO Wallet VM-test", udid: $gbo, state: $sg, isAvailable: true,
          deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
        {name: "iPhone Duo", udid: $base, state: "Shutdown", isAvailable: true,
          deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"}]
    }}' >"$FAKE_DEVICES"
  echo 1 >"$FAKE/slim/$IPHONE_1"
  echo 1 >"$FAKE/slim/$IPHONE_2"
  : >"$FAKE/apps/$IPHONE_1"
  : >"$FAKE/apps/$IPHONE_2"
  rm -rf "$TMP/state"
  : >"$XCRUN_TRACE"
}

state_of() {
  jq -r --arg u "$1" '[.devices[][] | select(.udid == $u) | .state][0]' "$FAKE_DEVICES"
}

dead_pid() {
  local pid
  sh -c 'echo $$' >"$TMP/pid"
  pid=$(cat "$TMP/pid")
  ! kill -0 "$pid" 2>/dev/null || fail "PID $pid is unexpectedly alive"
  printf '%s' "$pid"
}

# stale_lease UDID NAME: the record a holder leaves when it dies without cleanup.
stale_lease() {
  mkdir -p "$LEASES" "$LOCKS"
  jq -n --arg udid "$1" --arg name "$2" --argjson pid "$(dead_pid)" \
    '{udid: $udid, name: $name, pid: $pid, state: "running", started: "2026-01-01T00:00:00Z"}' \
    >"$LEASES/$1"
}

# A live holder of a device lock and its lease record, like a running lease.
hold() {
  local udid=$1 name=$2
  mkdir -p "$LEASES" "$LOCKS"
  flock "$LOCKS/$udid.lock" sleep 60 &
  HOLDERS+=("$!")
  jq -n --arg udid "$udid" --arg name "$name" --argjson pid "$!" \
    '{udid: $udid, name: $name, pid: $pid, state: "running", started: "2026-01-01T00:00:00Z"}' \
    >"$LEASES/$udid"
  sleep 0.3
}

release_holders() {
  local pid
  for pid in "${HOLDERS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  HOLDERS=()
}

mutations_of() {
  grep -E "^(simctl (boot|shutdown|uninstall|keychain|erase|delete)|simslim (on|off)) .*$1" "$XCRUN_TRACE" || true
}

assert_no_violation() {
  [[ ! -s $FAKE/violations ]] || fail "a protected UDID was touched: $(cat "$FAKE/violations")"
  if grep -Eiq "$GBO|$DUO_BASE" <(grep -vE '^simctl list ' "$XCRUN_TRACE"); then
    fail "a protected UDID reached a simulator operation: $(cat "$XCRUN_TRACE")"
  fi
}

# 1. The connection drops while the command runs (an SSH session without a
#    terminal just closes its pipes): the command dies of SIGPIPE, and
#    sim-lease must still wipe and shut down the sim and release the lease
#    instead of dying of SIGPIPE on its first cleanup message.
devices Shutdown Shutdown
set +e
"$SIM_LEASE" run -- sh -c '
  echo com.example.leftover >>"$FAKE/apps/$SIM_UDID"
  echo leased-command
  sleep 1
  echo still-running' 2>&1 | sed -n '/^leased-command$/q'
set -e
grep -q "^simctl boot $IPHONE_1" "$XCRUN_TRACE" || fail "setup: the dropped run did not boot pool-test-iphone-1"
[[ $(state_of "$IPHONE_1") == Shutdown ]] || fail "a dropped run left pool-test-iphone-1 $(state_of "$IPHONE_1")"
grep -q "^simctl uninstall $IPHONE_1 com.example.leftover" "$XCRUN_TRACE" ||
  fail "a dropped run did not wipe its sim: $(cat "$XCRUN_TRACE")"
[[ ! -e $LEASES/$IPHONE_1 ]] || fail "a dropped run left its lease record"
assert_no_violation

# 2. A holder killed outright (SIGKILL: no trap runs) leaves its sim booted with
#    a stale lease. The next run reclaims it: with the protected GBO sim booted
#    the stale sim fills the second slot, so it must be shut down and wiped and
#    then leased, not counted as external forever.
devices Shutdown Shutdown
set +e
"$SIM_LEASE" run -- sh -c '
  echo com.example.leftover >>"$FAKE/apps/$SIM_UDID"
  kill -KILL "$PPID"' >/dev/null 2>&1
set -e
[[ $(state_of "$IPHONE_1") == Booted ]] || fail "setup: the killed run did not leave pool-test-iphone-1 booted"
[[ -f $LEASES/$IPHONE_1 ]] || fail "setup: the killed run did not leave its lease record"
status=$("$SIM_LEASE" status)
grep -q "pool-test-iphone-1 $IPHONE_1 Booted STALE pid=" <<<"$status" || fail "killed lease not STALE: $status"
grep -q "pool-test-iphone-1 $IPHONE_1 ORPHAN pool sim" <<<"$status" || fail "killed lease not ORPHAN: $status"
: >"$XCRUN_TRACE"
set +e
output=$(timeout 10 "$SIM_LEASE" run -- sh -c 'echo "leased=$SIM_UDID"' 2>&1)
rc=$?
set -e
[[ $rc -eq 0 ]] || fail "run after a killed lease (rc=$rc): $output"
grep -q "^leased=$IPHONE_1\$" <<<"$output" || fail "run did not lease the reclaimed sim: $output"
grep -q "^simctl uninstall $IPHONE_1 com.example.leftover" "$XCRUN_TRACE" ||
  fail "the reclaimed sim was not wiped: $(cat "$XCRUN_TRACE")"
first_boot=$(grep -n "^simctl boot $IPHONE_1" "$XCRUN_TRACE" | head -n1 | cut -d: -f1)
first_shutdown=$(grep -n "^simctl shutdown $IPHONE_1" "$XCRUN_TRACE" | head -n1 | cut -d: -f1)
[[ -n $first_shutdown && -n $first_boot && $first_shutdown -lt $first_boot ]] ||
  fail "the stale sim was not shut down before its new lease: $(cat "$XCRUN_TRACE")"
[[ $(state_of "$IPHONE_1") == Shutdown && $(state_of "$IPHONE_2") == Shutdown ]] ||
  fail "pool sims left booted: $(cat "$FAKE_DEVICES")"
[[ $(state_of "$GBO") == Booted ]] || fail "the protected GBO sim changed state"
[[ -z $(ls -A "$LEASES") ]] || fail "lease records left: $(ls "$LEASES")"
assert_no_violation

# 3. A live lease is never taken: pool-test-iphone-1 is leased by a live holder
#    and, with GBO, fills the cap; a run waits and touches nothing.
devices Booted Shutdown
hold "$IPHONE_1" pool-test-iphone-1
set +e
output=$(timeout 3 "$SIM_LEASE" run -- true 2>&1)
rc=$?
set -e
[[ $rc -eq 124 ]] || fail "run should wait while a live lease fills the cap (rc=$rc): $output"
grep -q 'boot limit reached (2/2)' <<<"$output" || fail "no cap message: $output"
[[ -z $(mutations_of "$IPHONE_1") ]] || fail "a live lease was touched: $(cat "$XCRUN_TRACE")"
release_holders
assert_no_violation

# 4. A lock still held by a process that outlived a dead lease holder (for
#    example a child that inherited the lock) is not stolen either: lock
#    ownership, not the recorded PID, decides.
devices Booted Shutdown
mkdir -p "$LOCKS"
flock "$LOCKS/$IPHONE_1.lock" sleep 60 &
HOLDERS+=("$!")
sleep 0.3
stale_lease "$IPHONE_1" pool-test-iphone-1
set +e
output=$(timeout 3 "$SIM_LEASE" run -- true 2>&1)
rc=$?
set -e
[[ $rc -eq 124 ]] || fail "run should wait while the lock is held (rc=$rc): $output"
[[ -z $(mutations_of "$IPHONE_1") ]] || fail "a held lock was taken: $(cat "$XCRUN_TRACE")"
release_holders
assert_no_violation

# 5. undo on a pool sim left booted by a dead lease re-slims, wipes and shuts it
#    down, and the next run accepts it.
devices Booted Shutdown Shutdown
stale_lease "$IPHONE_1" pool-test-iphone-1
echo com.example.leftover >"$FAKE/apps/$IPHONE_1"
echo 0 >"$FAKE/slim/$IPHONE_1"
"$SIM_LEASE" undo "$IPHONE_1"
[[ $(cat "$FAKE/slim/$IPHONE_1") == 1 ]] || fail "undo left the pool sim un-slimmed"
grep -q "^simslim verify $IPHONE_1" "$XCRUN_TRACE" || fail "undo did not verify simslim"
[[ $(state_of "$IPHONE_1") == Shutdown ]] || fail "undo left the pool sim $(state_of "$IPHONE_1")"
[[ ! -s $FAKE/apps/$IPHONE_1 ]] || fail "undo did not wipe the pool sim"
[[ ! -e $LEASES/$IPHONE_1 ]] || fail "undo left the stale lease record"
: >"$XCRUN_TRACE"
output=$(SIM_LEASE_POOL_SIZE=1 timeout 10 "$SIM_LEASE" run -- sh -c 'echo "leased=$SIM_UDID"' 2>&1) ||
  fail "run after undo failed: $output"
grep -q "^leased=$IPHONE_1\$" <<<"$output" || fail "run after undo: $output"
assert_no_violation

# 6. undo --stock is the explicit teardown step: it un-slims, verifies stock and
#    shuts the sim down; a later run refuses it until init.
devices Shutdown Shutdown Shutdown
output=$("$SIM_LEASE" undo --stock "$IPHONE_1" 2>&1) || fail "undo --stock failed: $output"
[[ $(cat "$FAKE/slim/$IPHONE_1") == 0 ]] || fail "undo --stock left the sim slim"
grep -q '0/40 managed launchd labels disabled' <<<"$output" || fail "undo --stock status: $output"
[[ $(state_of "$IPHONE_1") == Shutdown ]] || fail "undo --stock left the sim $(state_of "$IPHONE_1")"
assert_no_violation

# 7. undo refuses a live lease and the protected sims, in either mode.
devices Booted Shutdown Shutdown
hold "$IPHONE_1" pool-test-iphone-1
set +e
output=$("$SIM_LEASE" undo "$IPHONE_1" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]] || ! grep -q 'has a live lease; undo cannot change it' <<<"$output"; then
  fail "undo took a live lease (rc=$rc): $output"
fi
[[ -z $(mutations_of "$IPHONE_1") ]] || fail "undo touched a live lease: $(cat "$XCRUN_TRACE")"
release_holders
for udid in "$GBO" "$DUO_BASE" "${GBO,,}"; do
  for mode in '' --stock; do
    set +e
    # shellcheck disable=SC2086 # an empty mode is no argument
    output=$("$SIM_LEASE" undo $mode "$udid" 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 ]] || ! grep -q 'is protected (known non-pool); refusing every simulator operation' <<<"$output"; then
      fail "undo $mode $udid was not refused (rc=$rc): $output"
    fi
  done
done
assert_no_violation

echo 'recovery test: PASS'
