# shellcheck shell=bash

PREFIX=${SIM_LEASE_PREFIX:-pool-}
IPHONE_POOL_SIZE=${SIM_LEASE_POOL_SIZE:-2}
DUO_POOL_SIZE=${SIM_LEASE_DUO_POOL_SIZE:-1}
POOL_SIZE_FLAG=
POOL_SIZE=
# Device kinds sharing one prefix, queue, state directory, and boot cap.
# iphone: the base iPhone pool (default). duo: the iPhone Duo pool, which needs
# Apple's device-specific runtime (for example iOS-27-2-iPhone19-4).
DEVICE=iphone
MEMBER_STEM=iphone
DEVICE_TYPE_FLAG=
DUO_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-Duo
MAX_BOOTED=${SIM_LEASE_MAX_BOOTED:-2}
STATE_DIR=${SIM_LEASE_STATE_DIR:-/tmp/sim-lease}
POLL_INTERVAL=${SIM_LEASE_POLL_INTERVAL:-2}
DEVICE_TYPE_REQUEST=${SIM_LEASE_DEVICE_TYPE:-}
RUNTIME_REQUEST=${SIM_LEASE_RUNTIME:-}
DEVICE_TYPE=
RUNTIME=
CURRENT_UDID=
CURRENT_NAME=
CURRENT_STARTED=
CURRENT_TOKEN=
# The xcrun/simctl guard shims, put first on PATH for a lease's command. Set by
# the packaging; without it the command runs with the caller's PATH.
GUARD_DIR=${GUARD_DIR:-}
CAPACITY_ANNOUNCED=0
CAPACITY_WAITING=0
CURRENT_CLEANUP=slim
UNDO_STOCK=0

# Known non-pool devices. This list is additive: an environment variable can
# protect more UDIDs, but cannot remove a built-in protection.
PROTECTED_UDIDS=(
  "EDD04C40-B5A6-4135-A2BB-19444D4E00B4" # GBO Wallet VM-test
  "E1C0D127-94F5-4FF6-B9D8-400507B67947" # iPhone Duo base sim (not a pool member)
)
PROTECTED_EXTRA=${SIM_LEASE_PROTECTED_UDIDS:-}
if [[ -n $PROTECTED_EXTRA ]]; then
  read -r -a EXTRA_PROTECTED_UDIDS <<<"${PROTECTED_EXTRA//,/ }"
  PROTECTED_UDIDS+=("${EXTRA_PROTECTED_UDIDS[@]}")
fi

usage() {
  cat <<'EOF'
Usage:
  sim-lease init [--device iphone|duo] [--device-type TYPE] [--runtime RUNTIME] [--pool-size N] [--max-booted N]
  sim-lease run [--device iphone|duo] [--device-type TYPE] [--runtime RUNTIME] -- COMMAND [ARG ...]
  sim-lease status [--device iphone|duo] [--device-type TYPE] [--runtime RUNTIME]
  sim-lease undo [--device iphone|duo] [--stock] POOL_UDID
  sim-lease --help

Commands:
  init     Create missing fixed pool sims, run simslim on each, then shut them down.
  run      Queue for a boot slot, lease a pool sim, and run COMMAND with SIM_UDID.
  status   Show pool devices, lease liveness, booted devices, and orphans.
  undo     Reset one unprotected pool UDID for reuse: reclaim a stale lease, apply
           and verify simslim, clean it, and shut it down. With --stock, restore
           it to stock instead (teardown): run refuses it until init.

--device selects the pool: iphone (default, ${SIM_LEASE_PREFIX:-pool-}iphone-1..N)
or duo (iPhone Duo, ${SIM_LEASE_PREFIX:-pool-}duo-1..N, one sim by default).
--device-type cannot be combined with --device duo. The boot cap is shared by
all device kinds. run never creates, erases, or deletes a simulator. Cleanup uninstalls user apps, resets the
keychain, verifies simslim state, and shuts down only the leased pool sim.
EOF
}

log() {
  printf 'sim-lease: %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

is_protected_udid() {
  local candidate=${1^^} protected
  for protected in "${PROTECTED_UDIDS[@]}"; do
    [[ $candidate == "${protected^^}" ]] && return 0
  done
  return 1
}

assert_unprotected_udid() {
  local udid=$1
  if is_protected_udid "$udid"; then
    die "$udid is protected (known non-pool); refusing every simulator operation"
  fi
}

select_device() {
  case $DEVICE in
    iphone)
      MEMBER_STEM=iphone
      POOL_SIZE=${POOL_SIZE_FLAG:-$IPHONE_POOL_SIZE}
      IPHONE_POOL_SIZE=$POOL_SIZE
      ;;
    duo)
      [[ -z $DEVICE_TYPE_FLAG ]] || die "--device-type cannot be combined with --device duo"
      MEMBER_STEM=duo
      POOL_SIZE=${POOL_SIZE_FLAG:-$DUO_POOL_SIZE}
      DUO_POOL_SIZE=$POOL_SIZE
      DEVICE_TYPE_REQUEST=$DUO_DEVICE_TYPE
      ;;
    *)
      die "unknown device: $DEVICE (expected iphone or duo)"
      ;;
  esac
}

validate_settings() {
  [[ $PREFIX =~ ^pool-[A-Za-z0-9._-]*$ ]] || die "SIM_LEASE_PREFIX must match pool-[A-Za-z0-9._-]*"
  [[ $IPHONE_POOL_SIZE =~ ^[1-9][0-9]*$ ]] || die "pool size must be a positive integer"
  [[ $DUO_POOL_SIZE =~ ^[1-9][0-9]*$ ]] || die "Duo pool size must be a positive integer"
  [[ $MAX_BOOTED =~ ^[1-9][0-9]*$ ]] || die "max booted must be a positive integer"
  [[ $POLL_INTERVAL =~ ^[0-9]+([.][0-9]+)?$ ]] || die "poll interval must be numeric"
  POOL_STATE=$STATE_DIR/$PREFIX
  LEASE_DIR=$POOL_STATE/leases
  LOCK_DIR=$POOL_STATE/locks
  QUEUE_LOCK=$STATE_DIR/queue.lock
}

ensure_state() {
  mkdir -p "$LEASE_DIR" "$LOCK_DIR"
  : >>"$QUEUE_LOCK"
}

all_devices_json() {
  xcrun simctl list devices --json
}

booted_devices_json() {
  xcrun simctl list devices booted --json
}

# Flatten simctl's runtime-keyed object and retain the runtime on each record.
flatten_devices() {
  jq -c '.devices | to_entries[] | .key as $runtime | .value[] |
    select(.isAvailable != false) | . + {runtimeIdentifier: $runtime}'
}

resolve_config() {
  local types_json runtimes_json config
  types_json=$(xcrun simctl list devicetypes --json) || die "cannot list simulator device types"
  runtimes_json=$(xcrun simctl list runtimes --json) || die "cannot list simulator runtimes"
  config=$(jq -ner --argjson types "$types_json" --argjson runtimes "$runtimes_json" \
    --arg type_request "$DEVICE_TYPE_REQUEST" --arg runtime_request "$RUNTIME_REQUEST" \
    --arg device "$DEVICE" '
      [$runtimes.runtimes[] as $runtime |
        select($runtime.isAvailable == true and $runtime.platform == "iOS") |
        select($runtime_request == "" or $runtime.name == $runtime_request or
          $runtime.version == $runtime_request or $runtime.identifier == $runtime_request) |
        select($runtime_request != "" or ($runtime.identifier | test(
          if $device == "duo" then "SimRuntime[.]iOS-[0-9-]+(-iPhone[0-9]+-[0-9]+)?$"
          else "SimRuntime[.]iOS-[0-9-]+$" end))) |
        $types.devicetypes[] as $type |
        select(any($runtime.supportedDeviceTypes[]?; .identifier == $type.identifier)) |
        select($type_request == "" or $type.name == $type_request or $type.identifier == $type_request) |
        select($type_request != "" or
          ($type.identifier | test("SimDeviceType[.]iPhone-[0-9]+$"))) |
        {
          runtime: $runtime.identifier,
          deviceType: $type.identifier,
          runtimeVersion: ($runtime.version | split(".") | map(tonumber)),
          deviceModel: (($type.identifier | capture("iPhone-(?<model>[0-9]+)$") | .model | tonumber) // 0)
        }
      ] |
      sort_by([.runtimeVersion, .deviceModel]) |
      if length > 0 then .[-1] else error("no compatible installed iOS runtime and device type") end
    ') || die "no installed iOS runtime/device type matches ${RUNTIME_REQUEST:-default} and ${DEVICE_TYPE_REQUEST:-default}"
  DEVICE_TYPE=$(jq -r '.deviceType' <<<"$config")
  RUNTIME=$(jq -r '.runtime' <<<"$config")
}

pool_name() {
  printf '%s%s-%s' "$PREFIX" "$MEMBER_STEM" "$1"
}

# A prefix alone is not ownership: pool- must not match pool-ipad- or a user's
# unrelated pool-notes simulator. Only exact fixed member names are managed.
# Members of every device kind under this prefix count, so an orphaned Duo is
# recovered by an iPhone run and vice versa.
is_pool_member_name() {
  local name=$1 stem size index
  for stem in iphone duo; do
    [[ $name == "${PREFIX}${stem}-"* ]] || continue
    index=${name#"${PREFIX}${stem}-"}
    [[ $index =~ ^[1-9][0-9]*$ ]] || continue
    if [[ $stem == iphone ]]; then size=$IPHONE_POOL_SIZE; else size=$DUO_POOL_SIZE; fi
    ((index <= size)) && return 0
  done
  return 1
}

lease_file() {
  printf '%s/%s' "$LEASE_DIR" "$1"
}

device_lock_file() {
  printf '%s/%s.lock' "$LOCK_DIR" "$1"
}

lease_pid() {
  jq -er '.pid | select(type == "number" and . > 0)' "$(lease_file "$1")" 2>/dev/null
}

# A per-lease token. The guard shims let a simctl call on a leased sim through
# only from a process whose SIM_LEASE_TOKEN matches the lease record. It keeps
# out mistakes (a stale UDID, a helper outside the lease), not a determined
# caller of the same macOS user, who can read the record.
new_lease_token() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

# How many simctl calls the guard refused on this lease's sim.
report_refusals() {
  local count
  [[ -n $CURRENT_TOKEN && -f $STATE_DIR/guard.log ]] || return 0
  count=$(grep -cF -- "$CURRENT_TOKEN" "$STATE_DIR/guard.log" || true)
  if [[ $count =~ ^[1-9][0-9]*$ ]]; then
    log "warning: refused $count simctl calls on this sim from outside the lease (see $STATE_DIR/guard.log)"
  fi
}

lease_live() {
  local udid=$1 pid
  [[ -f $(lease_file "$udid") ]] || return 1
  pid=$(lease_pid "$udid") || return 1
  kill -0 "$pid" 2>/dev/null
}

# The device flock is authoritative: once acquired, no live holder can own the
# lease record. This also recovers if the dead holder's PID has been reused.
reclaim_lease_locked() {
  local udid=$1 file pid
  file=$(lease_file "$udid")
  [[ -e $file ]] || return 1
  pid=$(lease_pid "$udid" 2>/dev/null || printf 'unknown')
  log "stale lease for $udid (PID $pid); reclaiming"
  rm -f "$file"
}

write_lease() {
  local state=$1 file tmp
  file=$(lease_file "$CURRENT_UDID")
  tmp=$file.tmp.$$
  jq -n --arg udid "$CURRENT_UDID" --arg name "$CURRENT_NAME" \
    --arg state "$state" --arg started "$CURRENT_STARTED" --argjson pid "$$" \
    --arg token "$CURRENT_TOKEN" \
    '{udid: $udid, name: $name, pid: $pid, state: $state, started: $started, token: $token}' >"$tmp"
  mv "$tmp" "$file"
}

remove_user_apps() {
  local udid=$1 plist bundle bundles rc=0
  plist=$(mktemp "${TMPDIR:-/tmp}/sim-lease-apps.XXXXXX") || return 1
  if xcrun simctl listapps "$udid" >"$plist"; then
    if bundles=$(plutil -convert json -o - "$plist" | jq -r 'keys[]'); then
      while IFS= read -r bundle; do
        [[ -n $bundle && $bundle != com.apple.* ]] || continue
        log "uninstalling $bundle from $udid"
        xcrun simctl uninstall "$udid" "$bundle" || rc=1
      done <<<"$bundles"
    else
      log "warning: cannot decode user apps on $udid"
      rc=1
    fi
  else
    log "warning: cannot list user apps on $udid"
    rc=1
  fi
  rm -f "$plist"
  return "$rc"
}

clean_contents() {
  local udid=$1 rc=0
  assert_unprotected_udid "$udid"
  remove_user_apps "$udid" || rc=1
  xcrun simctl keychain "$udid" reset || rc=1
  # A lease may switch to dark mode; the next one starts in light mode.
  xcrun simctl ui "$udid" appearance light || rc=1
  if ! "$SIMSLIM" verify "$udid"; then
    log "warning: simslim verification failed for $udid; run init again before reuse"
    rc=1
  fi
  return "$rc"
}

# The caller must hold the device lease/lock and establish that this is a pool UDID.
cleanup_device() {
  local udid=$1 rc=0
  assert_unprotected_udid "$udid"
  log "cleaning pool sim $udid"
  clean_contents "$udid" || rc=1
  xcrun simctl shutdown "$udid" || rc=1
  return "$rc"
}

release_current() {
  local rc=$? cleanup_rc=0
  trap - EXIT INT TERM HUP
  set +e
  if [[ -n $CURRENT_UDID ]]; then
    # The caller may be gone: a dropped SSH session closes our output pipes.
    # SIGPIPE is ignored, so a failed write shows it; then clean up silently.
    exec 1>&2
    if ! log "releasing $CURRENT_NAME ($CURRENT_UDID)"; then
      exec 1>/dev/null 2>&1
    fi
    if [[ $CURRENT_CLEANUP == stock ]]; then
      log "shutting down stock pool sim $CURRENT_UDID"
      assert_unprotected_udid "$CURRENT_UDID"
      xcrun simctl shutdown "$CURRENT_UDID" || cleanup_rc=$?
    else
      cleanup_device "$CURRENT_UDID" || cleanup_rc=$?
    fi
    report_refusals
    rm -f "$(lease_file "$CURRENT_UDID")"
    flock -u 8
    exec 8>&-
    log "released $CURRENT_NAME ($CURRENT_UDID)"
    CURRENT_UDID=
  fi
  exec 9>&-
  if [[ $rc -eq 0 && $cleanup_rc -ne 0 ]]; then
    rc=$cleanup_rc
  fi
  exit "$rc"
}

install_cleanup_trap() {
  # Without this, the first write after the caller's pipes close (a dropped SSH
  # session) kills sim-lease before its EXIT trap can clean the sim. A failed
  # write is an error instead, which still ends in release_current.
  trap '' PIPE
  trap release_current EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

report_external_booted() {
  local json=$1
  while IFS= read -r device; do
    local name udid
    name=$(jq -r '.name' <<<"$device")
    udid=$(jq -r '.udid' <<<"$device")
    if is_protected_udid "$udid"; then
      log "protected booted sim (left untouched): $name ($udid)"
    elif is_pool_member_name "$name"; then
      if ! lease_live "$udid"; then
        log "orphan pool sim: $name ($udid)"
      fi
    else
      log "external/orphan booted sim (left untouched): $name ($udid)"
    fi
  done < <(flatten_devices <<<"$json")
}

clean_pool_orphans() {
  local json=$1 device name udid
  # Refuse ambiguous names before cleaning any orphan. The booted-only list is
  # not enough: a duplicate could be shut down and therefore absent from it.
  while IFS= read -r device; do
    name=$(jq -r '.name' <<<"$device")
    udid=$(jq -r '.udid' <<<"$device")
    is_protected_udid "$udid" && continue
    is_pool_member_name "$name" || continue
    find_pool_device "$name" >/dev/null || die "cannot resolve pool sim $name"
  done < <(flatten_devices <<<"$json")

  while IFS= read -r device; do
    name=$(jq -r '.name' <<<"$device")
    udid=$(jq -r '.udid' <<<"$device")
    is_protected_udid "$udid" && continue
    is_pool_member_name "$name" || continue
    exec 6<>"$(device_lock_file "$udid")"
    if ! flock -n 6; then
      # A running holder owns this lock. Never infer staleness from a snapshot.
      exec 6>&-
      continue
    fi
    reclaim_lease_locked "$udid" || true
    cleanup_device "$udid" || log "warning: orphan cleanup failed for $name ($udid)"
    flock -u 6
    exec 6>&-
  done < <(flatten_devices <<<"$json")
}

booted_count() {
  jq '[.devices[]? | .[] | select(.state == "Booted")] | length' <<<"$1"
}

active_count() {
  jq '[.devices[]? | .[] | select(.state != "Shutdown")] | length' <<<"$1"
}

wait_for_boot_slot() {
  local json active_json count
  while true; do
    json=$(booted_devices_json) || die "cannot list booted simulators"
    if [[ $CAPACITY_ANNOUNCED -eq 0 ]]; then
      report_external_booted "$json"
      CAPACITY_ANNOUNCED=1
    fi
    clean_pool_orphans "$json"
    active_json=$(all_devices_json) || die "cannot count active simulators"
    count=$(active_count "$active_json")
    if ((count < MAX_BOOTED)); then
      return 0
    fi
    if [[ $CAPACITY_WAITING -eq 0 ]]; then
      log "boot limit reached ($count/$MAX_BOOTED); waiting in the machine-wide queue"
      CAPACITY_WAITING=1
    fi
    sleep "$POLL_INTERVAL"
  done
}

find_pool_device() {
  local name=$1 json
  local -a matches
  json=$(all_devices_json) || return 1
  mapfile -t matches < <(flatten_devices <<<"$json" | jq -c --arg name "$name" 'select(.name == $name)')
  ((${#matches[@]} <= 1)) || die "multiple simulators are named $name; refusing to choose one"
  if ((${#matches[@]} == 1)); then
    printf '%s\n' "${matches[0]}"
  fi
}

validate_pool_device() {
  local device=$1 name=$2 actual_type actual_runtime
  actual_type=$(jq -r '.deviceTypeIdentifier // empty' <<<"$device")
  actual_runtime=$(jq -r '.runtimeIdentifier // empty' <<<"$device")
  [[ $actual_type == "$DEVICE_TYPE" ]] || die "$name has device type $actual_type, expected $DEVICE_TYPE; use a separate SIM_LEASE_PREFIX"
  [[ $actual_runtime == "$RUNTIME" ]] || die "$name has runtime $actual_runtime, expected $RUNTIME; use a separate SIM_LEASE_PREFIX"
}

cmd_init() {
  local i name device udid count json active_json
  validate_settings
  resolve_config
  ensure_state
  install_cleanup_trap
  exec 9<>"$QUEUE_LOCK"
  flock -x 9
  log "initializing $POOL_SIZE sims ($DEVICE_TYPE, $RUNTIME)"

  for ((i = 1; i <= POOL_SIZE; i++)); do
    name=$(pool_name "$i")
    device=$(find_pool_device "$name")
    if [[ -n $device ]]; then
      validate_pool_device "$device" "$name"
      udid=$(jq -r '.udid' <<<"$device")
      assert_unprotected_udid "$udid"
      exec 6<>"$(device_lock_file "$udid")"
      if ! flock -n 6; then
        exec 6>&-
        die "$name has a live lease; init cannot change it"
      fi
      flock -u 6
      exec 6>&-
    fi
  done

  for ((i = 1; i <= POOL_SIZE; i++)); do
    name=$(pool_name "$i")
    device=$(find_pool_device "$name")
    if [[ -z $device ]]; then
      udid=$(xcrun simctl create "$name" "$DEVICE_TYPE" "$RUNTIME") || die "cannot create $name"
      log "created $name ($udid)"
    else
      udid=$(jq -r '.udid' <<<"$device")
    fi
    assert_unprotected_udid "$udid"
    while true; do
      json=$(booted_devices_json) || die "cannot list booted simulators"
      report_external_booted "$json"
      clean_pool_orphans "$json"
      active_json=$(all_devices_json) || die "cannot count active simulators"
      count=$(active_count "$active_json")
      ((count < MAX_BOOTED)) && break
      log "boot limit reached ($count/$MAX_BOOTED); waiting to slim $name"
      sleep "$POLL_INTERVAL"
    done
    exec 8<>"$(device_lock_file "$udid")"
    flock -x 8
    reclaim_lease_locked "$udid" || true
    CURRENT_UDID=$udid
    CURRENT_NAME=$name
    "$SIMSLIM" on "$udid"
    "$SIMSLIM" verify "$udid"
    cleanup_device "$udid"
    CURRENT_UDID=
    flock -u 8
    exec 8>&-
  done
  log "pool ready; all pool sims are shut down"
}

cmd_run() {
  local command=("$@") i name device udid state device_wait=0
  ((${#command[@]} > 0)) || die "run needs a command after --"
  validate_settings
  resolve_config
  ensure_state
  install_cleanup_trap

  # The queue is held through waiting and boot, but not while COMMAND runs.
  # Cleanups only need their device lock, so they can free capacity for a waiter.
  exec 9<>"$QUEUE_LOCK"
  flock -x 9
  while [[ -z $CURRENT_UDID ]]; do
    wait_for_boot_slot

    for ((i = 1; i <= POOL_SIZE; i++)); do
      name=$(pool_name "$i")
      device=$(find_pool_device "$name")
      [[ -n $device ]] || die "$name is missing; run sim-lease init with the same pool settings first"
      validate_pool_device "$device" "$name"
      udid=$(jq -r '.udid' <<<"$device")
      assert_unprotected_udid "$udid"
      exec 8<>"$(device_lock_file "$udid")"
      if ! flock -n 8; then
        exec 8>&-
        continue
      fi
      reclaim_lease_locked "$udid" || true
      state=$(jq -r '.state' <<<"$device")
      if [[ $state == Booted ]]; then
        cleanup_device "$udid"
      fi
      CURRENT_UDID=$udid
      CURRENT_NAME=$name
      CURRENT_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      CURRENT_TOKEN=$(new_lease_token)
      [[ $CURRENT_TOKEN =~ ^[0-9a-f]{32}$ ]] || die "cannot create a lease token"
      # sim-lease's own simctl calls on the sim (and simslim's) pass the guard.
      export SIM_LEASE_TOKEN=$CURRENT_TOKEN
      write_lease booting
      break
    done
    if [[ -z $CURRENT_UDID ]]; then
      if [[ $device_wait -eq 0 ]]; then
        log "all pool sims are still leased; waiting for a device"
        device_wait=1
      fi
      sleep "$POLL_INTERVAL"
    fi
  done

  log "booting $CURRENT_NAME ($CURRENT_UDID) with SIM_UDID"
  assert_unprotected_udid "$CURRENT_UDID"
  device=$(find_pool_device "$CURRENT_NAME") || die "cannot reread $CURRENT_NAME"
  if [[ $(jq -r '.state' <<<"$device") != Booted ]]; then
    xcrun simctl boot "$CURRENT_UDID"
  fi
  xcrun simctl bootstatus "$CURRENT_UDID" -b
  # Also clean on entry: a crashed holder may have left apps/keychain behind
  # even if another actor subsequently shut the simulator down.
  clean_contents "$CURRENT_UDID"
  write_lease running
  flock -u 9
  exec 9>&-
  log "leased $CURRENT_NAME to PID $$"

  set +e
  # COMMAND gets the default SIGPIPE disposition back.
  (
    trap - PIPE
    export SIM_UDID="$CURRENT_UDID" SIM_LEASE_DEVICE="$CURRENT_NAME"
    if [[ -n $GUARD_DIR ]]; then
      export PATH="$GUARD_DIR:$PATH"
    fi
    exec "${command[@]}"
  ) 8>&- 9>&-
  local rc=$?
  set -e
  exit "$rc"
}

cmd_undo() {
  local requested=$1 i name device udid found_name='' status_json
  validate_settings
  assert_unprotected_udid "$requested"
  resolve_config
  ensure_state
  for ((i = 1; i <= POOL_SIZE; i++)); do
    name=$(pool_name "$i")
    device=$(find_pool_device "$name")
    [[ -n $device ]] || continue
    udid=$(jq -r '.udid' <<<"$device")
    if [[ ${udid^^} == "${requested^^}" ]]; then
      found_name=$name
      break
    fi
  done
  [[ -n $found_name ]] || die "$requested is not a member of the selected pool; refusing undo"

  install_cleanup_trap
  exec 9<>"$QUEUE_LOCK"
  flock -x 9
  wait_for_boot_slot
  exec 8<>"$(device_lock_file "$udid")"
  if ! flock -n 8; then
    exec 8>&-
    die "$found_name has a live lease; undo cannot change it"
  fi
  reclaim_lease_locked "$udid" || true
  CURRENT_UDID=$udid
  CURRENT_NAME=$found_name
  if [[ $UNDO_STOCK -eq 1 ]]; then
    CURRENT_CLEANUP=stock
    "$SIMSLIM" off "$udid"
    status_json=$("$SIMSLIM" status "$udid" --json)
    jq -e '.managedDisabled == 0' <<<"$status_json" >/dev/null || die "simulator is not stock after undo"
    "$SIMSLIM" status "$udid"
    return
  fi
  # Leave the member as run expects it: slim and verified, then (on exit) clean
  # and shut down, exactly like the end of a lease.
  log "resetting $found_name ($udid) for reuse"
  "$SIMSLIM" on "$udid"
  "$SIMSLIM" verify "$udid"
}

cmd_status() {
  local i name device udid pid state lease json active_json booted active
  validate_settings
  resolve_config
  printf 'Pool: prefix=%s device=%s size=%s device-type=%s runtime=%s\n' "$PREFIX" "$DEVICE" "$POOL_SIZE" "$DEVICE_TYPE" "$RUNTIME"
  for ((i = 1; i <= POOL_SIZE; i++)); do
    name=$(pool_name "$i")
    device=$(find_pool_device "$name")
    if [[ -z $device ]]; then
      printf '  %s MISSING\n' "$name"
      continue
    fi
    udid=$(jq -r '.udid' <<<"$device")
    state=$(jq -r '.state' <<<"$device")
    if is_protected_udid "$udid"; then
      printf '  %s %s %s PROTECTED (never touched)\n' "$name" "$udid" "$state"
      continue
    fi
    lease=free
    if [[ -f $(lease_file "$udid") ]]; then
      pid=$(lease_pid "$udid" 2>/dev/null || printf 'unknown')
      if lease_live "$udid"; then
        lease="leased pid=$pid"
      else
        lease="STALE pid=$pid"
      fi
    fi
    printf '  %s %s %s %s\n' "$name" "$udid" "$state" "$lease"
  done

  active_json=$(all_devices_json) || die "cannot count active simulators"
  active=$(active_count "$active_json")
  printf 'Active (not Shutdown): %s (configured cap %s; all sims counted)\n' "$active" "$MAX_BOOTED"
  json=$(booted_devices_json) || die "cannot list booted simulators"
  booted=$(booted_count "$json")
  printf 'Booted: %s\n' "$booted"
  while IFS= read -r device; do
    name=$(jq -r '.name' <<<"$device")
    udid=$(jq -r '.udid' <<<"$device")
    if is_protected_udid "$udid"; then
      printf '  %s %s PROTECTED (never touched)\n' "$name" "$udid"
    elif is_pool_member_name "$name"; then
      if lease_live "$udid"; then
        printf '  %s %s leased (not orphan)\n' "$name" "$udid"
      else
        printf '  %s %s ORPHAN pool sim\n' "$name" "$udid"
      fi
    else
      printf '  %s %s ORPHAN/EXTERNAL (never touched)\n' "$name" "$udid"
    fi
  done < <(flatten_devices <<<"$json")
}

COMMAND=${1:-}
if [[ $COMMAND == --help || $COMMAND == -h ]]; then
  usage
  exit 0
fi
[[ -n $COMMAND ]] || {
  usage >&2
  exit 2
}
shift

while (($#)); do
  case $1 in
    --device)
      (($# >= 2)) || die "--device needs a value (iphone or duo)"
      DEVICE=$2
      shift 2
      ;;
    --device-type)
      (($# >= 2)) || die "--device-type needs a value"
      DEVICE_TYPE_REQUEST=$2
      DEVICE_TYPE_FLAG=$2
      shift 2
      ;;
    --runtime)
      (($# >= 2)) || die "--runtime needs a value"
      RUNTIME_REQUEST=$2
      shift 2
      ;;
    --pool-size)
      (($# >= 2)) || die "--pool-size needs a value"
      POOL_SIZE_FLAG=$2
      shift 2
      ;;
    --max-booted)
      (($# >= 2)) || die "--max-booted needs a value"
      if [[ $COMMAND == run ]]; then
        log "ignoring --max-booted for run; use the shared SIM_LEASE_MAX_BOOTED configuration"
      else
        MAX_BOOTED=$2
      fi
      shift 2
      ;;
    --stock)
      [[ $COMMAND == undo ]] || die "--stock is only valid for undo"
      UNDO_STOCK=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

select_device

case $COMMAND in
  init)
    (($# == 0)) || die "init takes no positional arguments"
    cmd_init
    ;;
  run)
    (($# > 0)) || die "run requires -- followed by a command"
    cmd_run "$@"
    ;;
  status)
    (($# == 0)) || die "status takes no positional arguments"
    cmd_status
    ;;
  undo)
    (($# == 1)) || die "undo takes exactly one pool UDID"
    cmd_undo "$1"
    ;;
  *)
    die "unknown command: $COMMAND (expected init, run, status, or undo)"
    ;;
esac
