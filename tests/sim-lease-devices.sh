#!/usr/bin/env bash
# Device selection tests for sim-lease, against a fake read-only xcrun.
# Covers --device parsing, the unchanged iPhone default, the boot cap shared by
# all device kinds, and the protected iPhone Duo base simulator.
set -euo pipefail

SIM_LEASE=${1:?usage: sim-lease-devices.sh /path/to/sim-lease}
DUO_BASE=E1C0D127-94F5-4FF6-B9D8-400507B67947
IPHONE_1=11111111-1111-4111-8111-111111111111
IPHONE_2=22222222-2222-4222-8222-222222222222
DUO_1=33333333-3333-4333-8333-333333333333
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
mkdir -p "$TMP/bin" "$TMP/state"
export SIM_LEASE_PREFIX=pool-test-
export SIM_LEASE_STATE_DIR=$TMP/state
export SIM_LEASE_POLL_INTERVAL=0.2
unset SIM_LEASE_POOL_SIZE SIM_LEASE_DUO_POOL_SIZE SIM_LEASE_DEVICE_TYPE SIM_LEASE_RUNTIME
export XCRUN_TRACE=$TMP/trace
export FAKE_DEVICES=$TMP/devices.json

cat >"$TMP/bin/xcrun" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$XCRUN_TRACE"
case "$*" in
  'simctl list devicetypes --json')
    cat <<'JSON'
{"devicetypes":[
 {"name":"iPhone 17","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
 {"name":"iPhone 17 Pro","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"},
 {"name":"iPhone Duo","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"}]}
JSON
    ;;
  'simctl list runtimes --json')
    cat <<'JSON'
{"runtimes":[
 {"isAvailable":true,"platform":"iOS","version":"27.2","name":"iOS 27.2","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4","supportedDeviceTypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"}]},
 {"isAvailable":true,"platform":"iOS","version":"27.2","name":"iOS 27.2","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2","supportedDeviceTypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"},{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"}]}]}
JSON
    ;;
  'simctl list devices --json')
    cat "$FAKE_DEVICES"
    ;;
  'simctl list devices booted --json')
    jq '.devices |= map_values(map(select(.state == "Booted")))' "$FAKE_DEVICES"
    ;;
  *)
    echo "unexpected simulator mutation: $*" >&2
    exit 99
    ;;
esac
SH
chmod +x "$TMP/bin/xcrun"
export PATH=$TMP/bin:$PATH

IPHONE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17
DUO_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-Duo
IPHONE_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-2
DUO_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4

# devices STATE_IPHONE_1 STATE_IPHONE_2 STATE_DUO_1 [DUO_1_UDID]
devices() {
  jq -n --arg s1 "$1" --arg s2 "$2" --arg s3 "$3" --arg duo "${4:-$DUO_1}" \
    --arg i1 "$IPHONE_1" --arg i2 "$IPHONE_2" --arg base "$DUO_BASE" \
    --arg it "$IPHONE_TYPE" --arg dt "$DUO_TYPE" --arg ir "$IPHONE_RUNTIME" --arg dr "$DUO_RUNTIME" '
    {devices: {
      ($ir): [
        {name: "pool-test-iphone-1", udid: $i1, state: $s1, isAvailable: true, deviceTypeIdentifier: $it},
        {name: "pool-test-iphone-2", udid: $i2, state: $s2, isAvailable: true, deviceTypeIdentifier: $it}],
      ($dr): ([{name: "pool-test-duo-1", udid: $duo, state: $s3, isAvailable: true, deviceTypeIdentifier: $dt}] +
        (if $duo == $base then [] else
          [{name: "iPhone Duo", udid: $base, state: "Shutdown", isAvailable: true, deviceTypeIdentifier: $dt}] end))
    }}' >"$FAKE_DEVICES"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_fail() {
  local pattern=$1 output rc
  shift
  set +e
  output=$("$SIM_LEASE" "$@" 2>&1)
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "sim-lease $* should fail"
  grep -q -- "$pattern" <<<"$output" || fail "sim-lease $*: expected '$pattern', got: $output"
}

assert_no_mutation() {
  if grep -Eq 'simctl (create|boot|shutdown|uninstall|keychain|ui|erase|delete|launchctl)' "$XCRUN_TRACE"; then
    fail "a simulator mutation was attempted: $(cat "$XCRUN_TRACE")"
  fi
}

devices Shutdown Shutdown Shutdown
: >"$XCRUN_TRACE"

# Default unchanged: no flag selects the iPhone pool, two members, base runtime.
status=$("$SIM_LEASE" status)
grep -q "^Pool: prefix=pool-test- device=iphone size=2 device-type=$IPHONE_TYPE runtime=$IPHONE_RUNTIME\$" <<<"$status" ||
  fail "default status: $status"
grep -q "pool-test-iphone-1 $IPHONE_1 Shutdown free" <<<"$status" || fail "default member 1: $status"
grep -q "pool-test-iphone-2 $IPHONE_2 Shutdown free" <<<"$status" || fail "default member 2: $status"
if grep -q 'pool-test-duo-' <<<"$status"; then fail "default status lists Duo members: $status"; fi
[[ $(SIM_LEASE_POOL_SIZE=1 "$SIM_LEASE" status | head -n1) == *"device=iphone size=1 "* ]] ||
  fail "SIM_LEASE_POOL_SIZE no longer sizes the iPhone pool"
[[ $("$SIM_LEASE" status --device iphone | head -n1) == "$(head -n1 <<<"$status")" ]] ||
  fail "--device iphone differs from the default"

# --device duo: one Duo member on the device-specific runtime.
status=$("$SIM_LEASE" status --device duo)
grep -q "^Pool: prefix=pool-test- device=duo size=1 device-type=$DUO_TYPE runtime=$DUO_RUNTIME\$" <<<"$status" ||
  fail "duo status: $status"
grep -q "pool-test-duo-1 $DUO_1 Shutdown free" <<<"$status" || fail "duo member: $status"
if grep -q 'pool-test-iphone-' <<<"$status"; then fail "duo status lists iPhone members: $status"; fi
[[ $("$SIM_LEASE" status --device duo --pool-size 2 | head -n1) == *"device=duo size=2 "* ]] ||
  fail "--pool-size does not size the Duo pool"
# A host-wide iPhone device-type setting does not redirect a Duo request.
[[ $(SIM_LEASE_DEVICE_TYPE='iPhone 17 Pro' "$SIM_LEASE" status --device duo | head -n1) == *"device-type=$DUO_TYPE "* ]] ||
  fail "SIM_LEASE_DEVICE_TYPE overrode the Duo device type"

# Flag parsing errors.
expect_fail 'unknown device: ipad (expected iphone or duo)' status --device ipad
expect_fail '--device needs a value' status --device
expect_fail '--device-type cannot be combined with --device duo' status --device duo --device-type 'iPhone 17'
expect_fail 'unknown device: duo2' run --device duo2 -- true
expect_fail 'Duo pool size must be a positive integer' status --device duo --pool-size 0
assert_no_mutation

# Global cap across device kinds. Live holders keep their device locks, so the
# waiting run must neither clean them nor boot anything.
hold() {
  local udid=$1
  mkdir -p "$TMP/state/pool-test-/locks"
  flock "$TMP/state/pool-test-/locks/$udid.lock" sleep 60 &
  HOLDERS+=("$!")
}
release_holders() {
  local pid
  for pid in "${HOLDERS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  HOLDERS=()
}
expect_waits() {
  local output rc
  : >"$XCRUN_TRACE"
  set +e
  output=$(timeout 3 "$SIM_LEASE" "$@" 2>&1)
  rc=$?
  set -e
  [[ $rc -eq 124 ]] || fail "sim-lease $* should wait at the cap (rc=$rc): $output"
  grep -q 'boot limit reached (2/2)' <<<"$output" || fail "sim-lease $*: no cap message: $output"
  assert_no_mutation
}

# Two iPhones booted: a Duo request waits.
devices Booted Booted Shutdown
hold "$IPHONE_1"
hold "$IPHONE_2"
sleep 0.3
expect_waits run --device duo -- true
release_holders

# One iPhone and one Duo booted: both an iPhone and a Duo request wait.
devices Booted Shutdown Booted
hold "$IPHONE_1"
hold "$DUO_1"
sleep 0.3
expect_waits run -- true
expect_waits run --device duo -- true
release_holders

# Protected Duo base sim: even renamed to a Duo pool member, never touched.
devices Shutdown Shutdown Booted "$DUO_BASE"
: >"$XCRUN_TRACE"
status=$("$SIM_LEASE" status --device duo)
grep -q "pool-test-duo-1 $DUO_BASE Booted PROTECTED (never touched)" <<<"$status" || fail "protected duo status: $status"
expect_fail 'is protected (known non-pool); refusing every simulator operation' init --device duo
expect_fail 'is protected (known non-pool); refusing every simulator operation' undo --device duo "$DUO_BASE"
expect_fail 'is protected (known non-pool); refusing every simulator operation' undo "${DUO_BASE,,}"
assert_no_mutation

echo 'device-selection test: PASS'
