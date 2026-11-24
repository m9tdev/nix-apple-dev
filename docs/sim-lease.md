# Shared, slim iOS simulator leases (`sim-lease`)

`sim-lease` lets independent projects share a fixed set of reusable iOS
simulators on one Mac. It prevents the usual failure mode of CI creating and
booting another simulator for every job:

- a host-wide queue allows at most **two active simulators** by default,
  counting every simulator visible to `simctl` whose state is not `Shutdown`
  (`Booting` and other transitional states count too), not just pool members;
- the bundled, private `simslim` binary disables unneeded background daemons in
  each pool simulator;
- a lease exports the simulator UDID to the test command and always cleans and
  shuts down the simulator afterwards;
- stale leases are recovered through device-lock ownership; PID liveness is
  diagnostic and used for the `STALE` status label, not for mutation safety.

The tool is a plain Bash CLI. It does not depend on a particular CI system or
automation tool. Packages are available for `aarch64-darwin`; Xcode and an
installed iOS Simulator runtime are required.

## Install or run without installing

```sh
# Run directly; nothing is added to a profile.
nix run github:m9tdev/nix-apple-dev#sim-lease -- --help

# Or install the one public command in the user's Nix profile.
nix profile install github:m9tdev/nix-apple-dev#sim-lease
```

The upstream `simslim` binary is an internal implementation dependency, called
by its Nix store path. It is not exported as a flake package/app/overlay and is
not added to the command's PATH. Consequently its fleet-wide and destructive
commands are not exposed by this flake.

## One-time pool setup

```sh
sim-lease init
sim-lease status
```

By default this creates two simulators named `pool-iphone-1` and
`pool-iphone-2`, using the highest-numbered base iPhone device type supported by
the newest compatible, generally available installed iOS runtime. It runs `simslim on` and
`simslim verify` for each, then shuts it down. Existing matching pool members
are reused; missing ones are created. `init` refuses to change a simulator with
a live lease.

A normal `run` **never creates a simulator**. Use a separate prefix when a
different device type or runtime is wanted; one prefix cannot contain two
configurations under the same names. For example:

```sh
SIM_LEASE_PREFIX=pool-ipad- \
SIM_LEASE_DEVICE_TYPE='iPad (A16)' \
  sim-lease init --pool-size 2
```

Only use a prefix owned by this pool. Prefixes must start with `pool-`; the
safety checks and cleanup below apply only to exact `${prefix}iphone-N` member
names where `N` is within the configured pool size. In particular, the default
`pool-` prefix does not claim `pool-ipad-…`, differently named simulators, or
pool-looking numbers above the configured size.

## Request an iPhone Duo

The same prefix can also hold a separate iPhone Duo pool, one simulator named
`pool-duo-1` by default. Select it with `--device duo` on every command; without
the flag, every command keeps using the iPhone pool exactly as before.

```sh
# One-time setup of the Duo member (also counted against the boot cap).
sim-lease init --device duo
sim-lease status --device duo

# Lease it for a test.
sim-lease run --device duo -- sh -c \
  'xcodebuild test -scheme MyApp -destination "platform=iOS Simulator,id=$SIM_UDID"'
```

`--device duo` always uses the `com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`
device type, so it cannot be combined with `--device-type`, and a host-wide
`SIM_LEASE_DEVICE_TYPE` does not apply to it. iPhone Duo needs Apple's
device-specific simulator runtime (for example
`com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4`, listed as `iOS 27.2`
by `xcrun simctl list runtimes`); `sim-lease` selects the newest installed
runtime that supports the Duo. `--runtime` still narrows that choice.

The Duo pool follows the same rules as the iPhone pool: it is slimmed by `init`,
cleaned and shut down after each lease, and never created, erased, or deleted
by `run`. The active-simulator cap is shared: with the default cap of two, any
mix of iPhone and Duo leases (and other booted simulators) totals at most two,
and further requests of either kind wait in the same queue. Orphaned members of
either kind under the prefix are recovered by the next `run` of any kind.

Do not boot a hand-made Duo simulator for tests; a manually created base Duo
simulator is protected (below) and left alone. Size the Duo pool with
`--pool-size` or `SIM_LEASE_DUO_POOL_SIZE` (default `1`).

## Run a test

```sh
sim-lease run -- sh -c \
  'xcodebuild test -scheme MyApp -destination "platform=iOS Simulator,id=$SIM_UDID"'
```

`run` leases a free pool member, boots it, verifies its `simslim` state, and
exports these variables to the command:

| Variable | Value |
|---|---|
| `SIM_UDID` | UDID of the leased simulator; use this in the test destination |
| `SIM_LEASE_DEVICE` | Pool name, such as `pool-iphone-1` |

The command's exit status is preserved. Before the command starts, and again in
an EXIT/HUP/INT/TERM trap afterwards, `sim-lease` uninstalls non-Apple user
apps, resets the keychain, and verifies that the slim launchd overrides are
still present. Afterwards it also shuts down the simulator and releases the
lease. Entry cleaning covers a stale simulator that somebody shut down after a
holder crashed. Exit cleaning and shutdown happen even when the test fails.
Cleanup does not use `simctl erase`, so it does not depend on erase preserving
host-side launchd state.

If the caller goes away mid-run, for example when an SSH session without a
terminal drops and its output pipes close, the command typically dies of
`SIGPIPE`. `sim-lease` itself ignores `SIGPIPE` (the command gets the default
back), so it still cleans and shuts down the simulator and releases the lease,
with its remaining output discarded.

If a holder is killed with `SIGKILL`, its trap cannot run: the simulator stays
booted and `status` shows it `STALE` and `ORPHAN`. Its device lock is released
by the kernel. The next `run` of any kind acquires that lock and reclaims the
lease record, then cleans and shuts down the stale pool member before counting
active simulators, so a stale member never holds a slot of the boot cap. It
then leases a member as usual. The PID in the record is diagnostic: `status`
labels a dead PID `STALE`, while lock ownership—not a possibly reused PID—
decides whether recovery may mutate a sim. A member whose lock is still held
(by a live holder, or by any process that inherited the lock) is never taken.
`sim-lease undo` (below) resets one member by hand without waiting for a run.

Before booting, `run` executes `xcrun simctl list devices booted --json`. It
reports external booted simulators and orphaned pool members. It cleans and
shuts down only orphaned exact members (`iphone-N` or `duo-N`) of the prefix's pools. **It never shuts
down, erases, uninstalls from, or deletes a non-pool simulator.** Other pool
prefixes and even differently named `pool-…` devices are external too. The
script has no simulator-delete command and never deletes a simulator or runtime.

## Protected non-pool UDIDs

Protection takes precedence over every name check, even if a protected device
is renamed to an exact pool member name. The built-in list contains:

| Simulator | UDID |
|---|---|
| `GBO Wallet VM-test` | `EDD04C40-B5A6-4135-A2BB-19444D4E00B4` |
| `iPhone Duo` (base sim, not a pool member) | `E1C0D127-94F5-4FF6-B9D8-400507B67947` |

A protected UDID is never booted, shut down, wiped, erased, slimmed, or deleted.
Booted/orphan reports label it `protected` rather than `external/orphan`.
`init`, `run`, orphan cleanup, and `undo` all enforce this boundary.

Add more entries for one invocation with a comma- or space-separated list:

```sh
SIM_LEASE_PROTECTED_UDIDS='AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA,BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB' \
  sim-lease status
```

The variable is additive and cannot remove built-in protections. For a permanent
site list, add full UDIDs to `PROTECTED_UDIDS` near the top of
`pkgs/sim-lease.sh` and rebuild. Find a device's full UDID with
`xcrun simctl list devices --json`; do not use a name or short prefix as the
protection key.

External programs that do not use `sim-lease` can still boot a simulator after
the capacity check. Run all simulator-launching jobs through the same queue to
enforce the cap consistently.

## Commands

```text
sim-lease init [--device iphone|duo] [--device-type TYPE] [--runtime RUNTIME] [--pool-size N] [--max-booted N]
sim-lease run [--device iphone|duo] [--device-type TYPE] [--runtime RUNTIME] -- COMMAND [ARG ...]
sim-lease status [--device iphone|duo] [--device-type TYPE] [--runtime RUNTIME]
sim-lease undo [--device iphone|duo] [--stock] POOL_UDID
sim-lease --help
```

- `init`: create missing fixed pool members, apply and verify `simslim`, then
  shut down each member. It uses the same boot cap and queue as `run`.
- `run`: wait for capacity and a free lease, boot, run the command, clean, shut
  down, and release. Two commands can run concurrently with the default cap;
  a third waits.
- `status`: read-only pool, lease, active/booted-device, and orphan report.
- `undo`: reset exactly one unprotected member of the selected pool for reuse:
  reclaim a stale lease, apply and verify `simslim`, clean it, and shut it
  down. With `--stock`, restore it to stock instead, verify zero disabled
  managed services, and shut it down (teardown). Either way it refuses live
  leases and uses the same queue and active-sim cap.

## Environment and flags

Flags override the corresponding environment variable for that invocation.
`--device iphone|duo` (default `iphone`) selects the pool; `--pool-size` sizes
the selected pool only.

| Environment variable | Default | Meaning |
|---|---|---|
| `SIM_LEASE_PREFIX` | `pool-` | Owned pool-name prefix; must start with `pool-` |
| `SIM_LEASE_POOL_SIZE` | `2` | Number of fixed iPhone pool members, named `iphone-1..N` under the prefix |
| `SIM_LEASE_DUO_POOL_SIZE` | `1` | Number of fixed iPhone Duo pool members, named `duo-1..N` under the prefix |
| `SIM_LEASE_MAX_BOOTED` | `2` | Maximum active (`state != Shutdown`) simulators before a new pool boot; all sims count |
| `SIM_LEASE_DEVICE_TYPE` | Highest-numbered base iPhone supported by the selected runtime | Device-type name or identifier; flag: `--device-type` |
| `SIM_LEASE_RUNTIME` | Newest compatible general installed iOS runtime | Runtime name, version, or identifier; flag: `--runtime` |
| `SIM_LEASE_STATE_DIR` | `/tmp/sim-lease` | Shared queue and per-prefix lease/lock state |
| `SIM_LEASE_POLL_INTERVAL` | `2` | Seconds between capacity checks while queued |
| `SIM_LEASE_PROTECTED_UDIDS` | Empty | Additional comma- or space-separated protected UDIDs; built-ins always remain |
| `SIMSLIM_BOOT_TIMEOUT` | `10m` (upstream) | Optional timeout for `simslim on` during `init` |
| `SIMSLIM_SPAWN_TIMEOUT` | `2m` (upstream) | Optional per-launchd-transition timeout during `init` |

The queue lock is `$SIM_LEASE_STATE_DIR/queue.lock`, shared by all prefixes,
rather than living in a project checkout. Keep the state directory and
`SIM_LEASE_MAX_BOOTED` setting consistent across projects.

**Warning:** `SIM_LEASE_MAX_BOOTED` is read independently for every invocation;
it is not stored in the queue. Set it to the same value in shared host
configuration for every project and job. A single job with a larger environment
value can raise its own observed cap and overcommit the host. `--max-booted` is
accepted for `init` and configuration reports, but ignored with a warning for
`run`; that only prevents command-line flag overrides, not environment
overrides.

CoreSimulator itself is per macOS user, so every participating project must run
as that user for a common view of booted devices.

## Add it to a project's CI test steps

Initialize the pool once on the runner, not in every test job. Then replace the
project's simulator destination with the leased UDID:

```yaml
- name: iOS tests
  run: |
    nix run github:m9tdev/nix-apple-dev#sim-lease -- run -- \
      sh -c 'xcodebuild test -workspace MyApp.xcworkspace -scheme MyApp \
        -destination "platform=iOS Simulator,id=$SIM_UDID"'
```

For an npm project, the same pattern works with a test script that reads
`SIM_UDID`:

```sh
sim-lease run -- npm run test:ios
```

Do not wrap the command in another simulator launcher that boots a second
simulator. Use the exact UDID rather than a destination name such as
`iPhone 17`, which can select a non-pool device.

## Undo

`sim-lease undo` resets one pool member so that the next `run` accepts it, for
example a member left booted by a holder that died. It refuses a live lease,
reclaims a stale one, applies and verifies `simslim` (as `init` does), uninstalls
user apps, resets the keychain, and shuts the simulator down:

```sh
sim-lease undo POOL_UDID
```

For a Duo member, pass the device too: `sim-lease undo --device duo POOL_UDID`.
`sim-lease status` lists the pool UDIDs.

### Restore a member to stock

To take slimming off a member, for example before tearing the pool down, use
the explicit `--stock` step. First stop users of the pool. Restore one pool UDID
at a time to stock, verify that zero managed launchd labels remain disabled,
and leave it shut down:

```sh
sim-lease undo --stock POOL_UDID
# expected status output: 0/N managed launchd labels disabled (stock)
```

`undo --stock` calls the private `simslim off` implementation internally; do
not try to undo slimming by erasing a simulator.

**A stock simulator no longer matches the pool's slim profile.** A later `run`
that selects it boots it, fails `simslim verify`, cleans and shuts it down, and
returns an error. If the pool remains in service, run `sim-lease undo` (without
`--stock`) or `sim-lease init` again so every member is slim and verified.
Otherwise restore every pool member to stock before tearing the pool down as
below; do not leave a mixed stock/slim pool for future runs.

Deleting devices is separate and irreversible. Only after the pool owner agrees,
delete the explicitly identified pool UDIDs, never a name pattern or `all`:

```sh
xcrun simctl delete POOL_UDID
```

Never delete protected or other projects' simulators or any installed runtime.

To stop offering the Duo pool, restore `pool-duo-1` to stock as above, delete only its UDID
(from `sim-lease status --device duo`) if wanted, and stop passing
`--device duo`. The iPhone pool is unaffected. To go back to a release without
Duo support, also remove `pool-duo-1` first: older releases treat it as an
external simulator and never clean it.
Remove the public Nix command with:

```sh
nix profile remove sim-lease
```

The private `simslim` store-path dependency is not installed as a profile
command and has no separate flake app/package/overlay to remove.

## Tests

The tests run against fake `xcrun`, `simslim` and `plutil` commands, so they
need no simulator and also run on Linux. From a checkout, with bash, coreutils,
util-linux (`flock`) and jq (and shellcheck, if installed):

```sh
bash tests/sim-lease-local.sh
```

On macOS, `nix flake check` runs the same tests against the packaged command.
