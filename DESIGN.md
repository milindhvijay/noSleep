# Design

Technical notes on how noSleep is built and why. For installation and usage see
the [README](README.md).

## Architecture

noSleep ships two binaries:

| Binary | Language | Role |
| --- | --- | --- |
| `noSleep` | Swift | CLI for install-time and lifecycle commands |
| `noSleepDaemon` | C | the long-running process launchd starts at login |

The original implementation was a single Swift binary serving both roles. That
worked, but the resident process carried CLI helpers, Foundation
process-spawning utilities, and notification code it never used while idle.
Splitting the two keeps the always-running process small; the CLI keeps the
convenience code.

```text
Sources/noSleep/main.swift           CLI argument dispatch, help, version
Sources/noSleep/Commands.swift       status, start, stop, restart, doctor, uninstall
Sources/noSleep/Config.swift         paths, launchd label, version
Sources/noSleep/Lock.swift           state directory, lock file, PID read/write
Sources/noSleep/PowerState.swift     AC, clamshell, and battery reads via IOKit
Sources/noSleep/SleepPreventer.swift PreventSystemSleep assertion wrapper
Sources/noSleep/Daemon.swift         Swift fallback daemon
Sources/noSleep/Utilities.swift      bounded subprocess helper, PID validation
Sources/noSleep/noSleepDaemon.c      the daemon launchd runs
```

`noSleep daemon` execs `~/bin/noSleepDaemon` when it is present and executable,
and otherwise runs the Swift daemon in `Daemon.swift` as a fallback. The
fallback holds the same assertion under the same lock, but posts no
notifications and plays no sounds, and coalesces IOKit event bursts through a
150 ms debounce timer instead of acting on every callback.

## Power state and assertions

The daemon is event-driven and does not poll. It registers two run-loop sources:

- `IOServiceAddInterestNotification` on `IOPMrootDomain` for clamshell changes.
- `IOPSNotificationCreateRunLoopSource` for power-source changes.

On either event it reads `AppleClamshellState` and
`IOPSGetProvidingPowerSourceType`, then holds exactly one
`kIOPMAssertionTypePreventSystemSleep` assertion while the lid is closed on AC
power. `PreventSystemSleep` is the assertion type that survives a clamshell
close; display-sleep assertions do not.

Two related optimizations:

- The `IOPMrootDomain` service is looked up once and cached for the process
  lifetime rather than re-acquired on every lid read.
- The daemon skips the battery-percentage lookup entirely. It only needs AC and
  lid state; `status` and `doctor` still report percentage.

`messageType` from the clamshell notification varies across macOS versions, so
the callback ignores it and re-reads state instead.

## State and locking

State lives at `~/Library/Application Support/noSleep/noSleep.lock`, moved off
the original `/tmp/noSleep.lock`. `/tmp` is world-writable and shared, which
makes stale files, symlink games, and ownership surprises easy to hit for what
is really per-user daemon state. The legacy path is still read and cleaned when
it is safe to do so.

Locking is deliberately defensive on both sides of the Swift/C split:

- The state directory is created mode `0700`; the lock file mode `0600`.
- The lock file is opened `O_NOFOLLOW | O_CLOEXEC`, so a symlink at that path is
  refused rather than followed.
- After opening, `fstat` confirms the descriptor is a regular file, owned by the
  current UID, with `st_nlink == 1` — rejecting hardlink and file-type
  substitution.
- `flock(LOCK_EX | LOCK_NB)` provides the actual mutual exclusion.
- The PID is written with a full-write loop and flushed with `fsync`, so a
  partial write cannot leave a truncated PID behind.
- On shutdown the file is unlinked *before* the advisory lock is released, so
  another process cannot acquire the lock on an inode that is about to be
  deleted.

A PID from the lock file is never trusted on its own. Before it is reported or
signaled it must pass `kill(pid, 0)` and a `proc_pidpath` check confirming the
executable is actually `noSleep` or `noSleepDaemon`. The C daemon additionally
rejects PID text that overflows or carries trailing junk. Without this, a
recycled PID could be reported as a running daemon, or signaled.

## Notifications

| Transition | Body | Subtitle | Sound |
| --- | --- | --- | --- |
| Entering protected state | Sleep prevention active | AC Power + Lid Closed | none |
| Unplugged from AC | Normal behaviour restored | Switched to battery | Glass |
| Lid opened | Normal behaviour restored | Lid opened | Glass |
| Any other release | Normal behaviour restored | Ready to sleep | Glass |

Notifications are posted only when the assertion is actually created or
released, so the duplicate events IOKit delivers in bursts do not produce
duplicate alerts.

The lid-close sound is intentionally suppressed. macOS can defer audio while
transitioning into clamshell mode and then replay it on lid open, where it
stacks with the restore sound. One sound on restore is the reliable behavior.

Helpers are spawned with `posix_spawn` using absolute paths
(`/usr/bin/osascript`, `/usr/bin/afplay`) rather than shell strings. Each child
gets a fixed minimal environment:

```text
PATH=/usr/bin:/bin:/usr/sbin:/sbin
```

Inheriting the daemon's environment would hand children `TMPDIR`,
`SSH_AUTH_SOCK`, a custom `PATH`, and any `DYLD_*` values for no benefit, since
the executables are addressed absolutely anyway. Children also get `SIGTERM`
and `SIGINT` reset to default so timeout handling stays predictable, and their
stdio is opened on `/dev/null`.

Waits on helpers are bounded — roughly three seconds, then `SIGTERM`, then
`SIGKILL` — and reaped with `waitpid`. The original shell helper waited
indefinitely, so a stuck `osascript` could hang a CLI command or an event path.

## Signal handling and shutdown

The C daemon sets `SIGTERM` and `SIGINT` to `SIG_IGN`, registers them on a
kqueue, and wraps that descriptor in a `CFFileDescriptor` run-loop source.
Signal delivery stops the run loop and lets the ordinary cleanup path run:
release the assertion, invalidate the IOKit sources, release retained IOKit
objects, unlink the lock file.

This indirection exists because almost nothing in that cleanup path is
async-signal-safe. Calling CoreFoundation, IOKit, `flock`, or `unlink` from a
raw POSIX handler would be incorrect, even though it usually appears to work.
launchd and the CLI already stop the daemon cleanly, and macOS releases power
assertions when a process dies, so this only matters for a direct `kill` — but
it makes that case deterministic.

The kqueue descriptor is marked close-on-exec. It is not file-backed, so it
creates no filesystem or disk activity.

## Install and uninstall

`install.sh` runs under `set -e` with a seeded system `PATH`, and requires both
`swiftc` and `clang`.

On Apple silicon it reads the CPU brand and tries `-O -target-cpu apple-mN` for
the detected chip, walking down through older `apple-m*` targets and finally
falling back to a plain `-O` build. A new chip can ship before the local
compiler knows its `-target-cpu` spelling, and that should not break the
install.

The daemon is built into a `mktemp` path and copied into `~/bin`, so no daemon
artifact is left in the repository; an EXIT trap removes it. The generated
launch agent is validated with `plutil -lint` before being moved into place, so
launchd is never handed a malformed plist. If a daemon was already loaded, the
installer boots it out and back in, then waits for a fresh PID in the lock file
before reporting success.

The launch agent sets `RunAtLoad` and a `KeepAlive` dict with `SuccessfulExit`
set to `false`: launchd restarts the daemon if it exits non-zero, but not after
a clean shutdown. `StandardOutPath` and `StandardErrorPath` point at
`/dev/null`.

Lifecycle commands address launchd explicitly via `gui/<uid>/com.noSleep.daemon`
using `bootstrap`, `bootout`, and `kickstart`, and confirm readiness by polling
for a new validated PID rather than assuming the command took effect. This is
what makes `start` and `restart` able to fail honestly.

`uninstall` covers current and legacy paths:

```text
~/bin/noSleep
~/bin/noSleepDaemon
~/Library/LaunchAgents/com.noSleep.daemon.plist
~/Library/Application Support/noSleep/noSleep.lock
~/Library/Application Support/noSleep
~/Library/Logs/noSleep
/tmp/noSleep.lock
/tmp/noSleep.log
/tmp/noSleep.err
```

Every removal checks ownership and expected file type first, and reports what it
removed. Removal runs before and after the launchd teardown so a daemon that
recreates its lock during shutdown does not leave one behind.

## Build hardening

The daemon is compiled `-Os` with warnings promoted to errors:

```text
-Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wformat=2
-Wstrict-prototypes -Wmissing-prototypes -Wshadow -Werror
-fstack-protector-strong -fvisibility=hidden
```

C buys lower runtime overhead at the cost of Swift's memory safety, so the C
surface is kept small and warning-clean: fixed-size buffers are bounded and
checked, `snprintf` truncation is treated as an error, and CoreFoundation and
IOKit objects are released where owned. The intent is that a future unsafe
change fails the build rather than shipping.

The source is also kept `clang --analyze` clean. That is run manually — it is
not part of `install.sh`.

## Runtime footprint

After startup the daemon settles into one thread, no polling loop, no resident
notification worker, and one real open file descriptor: the lock file. Standard
descriptors are closed once initialization succeeds, since launchd's `/dev/null`
stdio is not needed and only showed up as noise in Activity Monitor.
Notification and sound helpers are short-lived children spawned only on real
transitions.

`lsof` and Activity Monitor will still show the executable, `dyld`, and cwd.
Those are runtime mappings, not files noSleep created. macOS may also report
page-ins or faults on first access to executable and shared-library pages;
those counters cannot be forced to zero. The daemon is structured to avoid idle
churn, not to make the tooling print zeros.

The absence of `~/Library/Logs/noSleep` on a healthy install is intentional.
The daemon does not log in normal operation.
