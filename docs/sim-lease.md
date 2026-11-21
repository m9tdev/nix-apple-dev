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

If a holder is killed with `SIGKILL`, its trap cannot run and its device lock is
released by the kernel. A later `run` acquires that lock and reclaims the lease
record, then cleans and shuts down the stale pool member before reuse. The PID
in the record is diagnostic: `status` labels a dead PID `STALE`, while lock
ownership—not a possibly reused PID—decides whether recovery may mutate a sim.

Before booting, `run` executes `xcrun simctl list devices booted --json`. It
reports external booted simulators and orphaned pool members. It cleans and
shuts down only orphaned exact members of the selected pool. **It never shuts
down, erases, uninstalls from, or deletes a non-pool simulator.** Other pool
prefixes and even differently named `pool-…` devices are external too. The
script has no simulator-delete command and never deletes a simulator or runtime.

## Protected non-pool UDIDs

Protection takes precedence over every name check, even if a protected device
is renamed to an exact pool member name. The built-in list contains:

| Simulator | UDID |
|---|---|
| `GBO Wallet VM-test` | `EDD04C40-B5A6-4135-A2BB-19444D4E00B4` |

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
sim-lease init [--device-type TYPE] [--runtime RUNTIME] [--pool-size N] [--max-booted N]
sim-lease run [--device-type TYPE] [--runtime RUNTIME] -- COMMAND [ARG ...]
sim-lease status [--device-type TYPE] [--runtime RUNTIME]
sim-lease undo POOL_UDID
sim-lease --help
```

- `init`: create missing fixed pool members, apply and verify `simslim`, then
  shut down each member. It uses the same boot cap and queue as `run`.
- `run`: wait for capacity and a free lease, boot, run the command, clean, shut
  down, and release. Two commands can run concurrently with the default cap;
  a third waits.
- `status`: read-only pool, lease, active/booted-device, and orphan report.
- `undo`: restore exactly one unprotected member of the selected pool to stock,
  verify zero disabled managed services, and shut it down. It refuses live
  leases and uses the same queue and active-sim cap.

## Environment and flags

Flags override the corresponding environment variable for that invocation.

| Environment variable | Default | Meaning |
|---|---|---|
| `SIM_LEASE_PREFIX` | `pool-` | Owned pool-name prefix; must start with `pool-` |
| `SIM_LEASE_POOL_SIZE` | `2` | Number of fixed pool members, named `iphone-1..N` under the prefix |
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
`SIM_LEASE_MAX_BOOTED` setting consistent across projects. `--max-booted` is
accepted for `init` and configuration reports, but ignored with a warning for
`run`, so one job cannot raise the shared cap through its command-line flags.
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

First stop users of the pool. Restore one pool UDID at a time to stock, verify
that zero managed launchd labels remain disabled, and leave it shut down:

```sh
sim-lease undo POOL_UDID
# expected status output: 0/N managed launchd labels disabled (stock)
```

`undo` calls the private `simslim off` implementation internally; do not try to
undo slimming by erasing a simulator. `sim-lease status` lists the pool UDIDs.

Deleting devices is separate and irreversible. Only after the pool owner agrees,
delete the explicitly identified pool UDIDs, never a name pattern or `all`:

```sh
xcrun simctl delete POOL_UDID
```

Never delete protected or other projects' simulators or any installed runtime.
Remove the public Nix command with:

```sh
nix profile remove sim-lease
```

The private `simslim` store-path dependency is not installed as a profile
command and has no separate flake app/package/overlay to remove.
