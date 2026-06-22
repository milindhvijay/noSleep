# Changelog

## ai_build

This branch hardens noSleep against correctness, security, cleanup, and runtime
overhead issues found during review of the original codebase and PR #2.

The original implementation was a single Swift binary that served both as the
CLI and the launchd daemon. It worked, but the always-running process carried
more code and runtime surface than needed, used `/tmp` for daemon state, trusted
PID files too loosely, and ran several command paths through shell strings.

The current implementation keeps the user-facing Swift CLI and adds a minimal C
daemon for the long-running launchd process.

### 1. Dedicated minimal daemon

Changed:

- Added `Sources/noSleep/noSleepDaemon.c`.
- `launchd` now runs `~/bin/noSleepDaemon`.
- `~/bin/noSleep` remains the CLI for status, start, stop, restart, doctor,
  daemon, and uninstall.

Why:

- The original daemon was the same Swift process as the CLI, so the resident
  daemon carried Foundation helpers, shell/process utilities, and notification
  machinery.
- The daemon only needs to monitor AC/lid state and hold or release a power
  assertion. Splitting it reduces the always-running code path.

Impact:

- Lower idle daemon footprint.
- One daemon thread in normal idle state.
- No polling loop.
- No permanent notification worker thread.
- `noSleep daemon` still works by execing the installed daemon when present,
  with the Swift daemon kept as a fallback.

### 2. Lock file moved out of `/tmp`

Changed:

- Primary lock file moved from `/tmp/noSleep.lock` to:

```text
~/Library/Application Support/noSleep/noSleep.lock
```

- Legacy `/tmp/noSleep.lock` is still checked and cleaned where safe.

Why:

- The original used a predictable world-writable directory for runtime state.
- `/tmp` is not ideal for a per-user daemon lock because stale files, symlinks,
  ownership surprises, and unrelated user/process interference are easier to
  encounter there.

Impact:

- Per-user state is now kept under the user's Application Support directory.
- The state directory is created with mode `0700`.
- The lock file is created with mode `0600`.

### 3. Lock-file security and correctness hardening

Changed:

- Lock files are opened with `O_NOFOLLOW` and `O_CLOEXEC`.
- The daemon validates lock file type, owner, and hardlink count.
- PID writes use a full-write loop.
- PID writes are flushed with `fsync`.
- The lock file is unlinked before releasing the advisory lock during normal
  cleanup.

Why:

- The original lock used `open(..., 0644)`, did not reject symlinks, did not
  validate file ownership/type, and wrote the PID without checking for partial
  writes.
- Those are low-probability but real correctness and security weaknesses in a
  daemon lock path.

Impact:

- Safer single-instance behavior.
- Better stale-lock handling.
- Lower risk of following or deleting an attacker-controlled path.

### 4. Safer PID validation

Changed:

- Status, stop, restart, doctor, and uninstall validate daemon PIDs with
  `proc_pidpath`.
- Both `noSleep` and `noSleepDaemon` are recognized as valid noSleep processes.

Why:

- The original status and lifecycle commands trusted a PID read from the lock
  file if `kill(pid, 0)` succeeded.
- A reused PID could point to an unrelated process.

Impact:

- CLI commands avoid reporting or acting on unrelated processes.
- Uninstall and stop behavior is less likely to signal the wrong process.

### 5. Direct process execution instead of shell strings

Changed:

- Swift command helpers now use `Process` with direct executable paths and
  argument arrays.
- The daemon uses `posix_spawn` directly for notifications and sounds.
- No shell is used for daemon notification/sound execution.

Why:

- The original used `zsh -c` for launchctl, plutil, and osascript commands.
- Shell strings increase quoting complexity and create avoidable injection and
  correctness risk.

Impact:

- Less shell quoting risk.
- Clearer command boundaries.
- Better timeout handling for helper processes.

### 6. Helper process timeout handling

Changed:

- Swift `run()` has a timeout and terminates stuck helper processes.
- The C daemon waits for notification/sound children and kills them if they do
  not exit in time.

Why:

- The original `shell()` helper waited indefinitely.
- A stuck helper could block a CLI command or notification path.

Impact:

- Lifecycle commands and event notifications are bounded.
- No expected zombie processes from notification/sound children.

### 7. Power-state handling split for daemon and diagnostics

Changed:

- `getCurrentPowerState(includeBattery:)` can skip battery percentage lookup.
- The daemon uses `includeBattery: false`.
- `status` and `doctor` can still show battery percentage.

Why:

- The original daemon collected battery percentage even though the daemon only
  needed AC power and lid state.

Impact:

- Less work in the daemon's event path.
- Diagnostic output remains useful.

### 8. Root domain service reuse

Changed:

- The Swift fallback caches the `IOPMrootDomain` service and releases it during
  cleanup.
- The C daemon also keeps a root-domain service for its lifetime.

Why:

- The original Swift code opened and released the root-domain service on every
  lid-state read.

Impact:

- Fewer repeated IOKit lookups in state checks.
- Cleaner ownership of IOKit objects.

### 9. Event-driven daemon retained; polling avoided

Changed:

- The daemon still uses IOKit clamshell and power-source notifications.
- No polling loop was added.

Why:

- The original event-driven design was the right shape for CPU usage.
- The fix keeps that design rather than replacing it with a timer loop.

Impact:

- Idle CPU remains effectively zero.
- State changes are handled by macOS notifications.

### 10. Duplicate event handling and assertion transitions

Changed:

- The Swift fallback uses a reusable debounce timer for duplicate IOKit bursts.
- The C daemon only notifies when an assertion is actually created or released.

Why:

- IOKit can deliver rapid duplicate events.
- The original had a simple in-process guard, but notification spawning could
  still be more expensive than needed.

Impact:

- Duplicate callbacks do not repeatedly create assertions or notifications.
- Notifications are tied to real state transitions.

### 11. Notification behavior adjusted for clamshell audio reality

Changed:

- Lid close posts the "Sleep prevention active" notification without forcing a
  sound.
- Restore/open posts "Normal behaviour restored" and plays one Glass sound.

Why:

- Explicit lid-close audio can be suppressed or deferred while macOS transitions
  into clamshell/display state, then replay on lid-open and stack with the
  restore sound.

Impact:

- Notifications remain visible.
- Lid-open restore has one audible confirmation.
- The double-sound lid-open behavior is avoided.

### 12. Launchd log files removed

Changed:

- The launchd plist sends stdout and stderr to `/dev/null`.
- `install.sh` no longer creates `~/Library/Logs/noSleep`.
- `uninstall` still removes old noSleep log paths if present.

Why:

- The daemon should not write logs in normal operation.
- Empty log files and a log directory were unnecessary filesystem footprint.

Impact:

- Cleaner filesystem.
- Fewer open files in the daemon.
- No idle log growth.
- The absence of `~/Library/Logs/noSleep` on a healthy install is intentional,
  not a failure to create logs.

### 13. Standard descriptors closed after daemon startup

Changed:

- `noSleepDaemon` closes fd `0`, `1`, and `2` after successful initialization.

Why:

- launchd-provided stdin/stdout/stderr pointed to `/dev/null`. They were safe,
  but still appeared as open files in Activity Monitor.
- The daemon does not need stdio once startup succeeds.

Impact:

- The live daemon's real open fd list is reduced to the lock file.
- Activity Monitor still shows cwd, executable, and dyld mappings because those
  are runtime mappings, not noSleep-created files.

### 14. Install script made stricter and cleaner

Changed:

- Installer checks for both `swiftc` and `clang`.
- CPU-specific Swift build tries the detected Apple CPU first, then falls back
  through older Apple CPU targets.
- Unsupported local CPU names such as a newer Apple M-series chip fall back
  cleanly instead of stopping the install.
- Empty compile logs are removed.
- The C daemon is built in a temporary path and copied into `~/bin`.
- The generated plist is validated with `plutil -lint` before installation.
- The installer uses macOS' system `zsh` path and seeds a standard system
  `PATH` for helper tools.

Why:

- The original install script was simpler but could leave unnecessary compile
  artifacts and did not validate the generated plist before launchd use.
- New Apple CPU names can appear before the local compiler supports their
  `-target-cpu` spelling.

Impact:

- Cleaner installs.
- Better compatibility with newer local Apple Silicon.
- No local `noSleepDaemon` build artifact is left in the repository.

### 15. Launchd lifecycle handling improved

Changed:

- Start, stop, restart, and uninstall use explicit launchd service paths.
- Restart uses launchd directly rather than replacing a running CLI process.
- Install restarts an existing daemon via launchctl after writing the new
  binaries and plist.

Why:

- The original lifecycle commands relied on shell snippets and simple plist
  paths.
- Replacing the currently running CLI binary during restart/uninstall can create
  edge cases.

Impact:

- More predictable start/stop/restart behavior.
- Cleaner upgrade path.

### 16. Uninstall cleanup broadened but kept ownership-aware

Changed:

- `noSleep uninstall` removes:

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

- File and directory removal checks ownership and expected type where practical.

Why:

- The original uninstall removed the Swift binary, plist, lock file, and old
  `/tmp` logs, but the hardened tree introduced a daemon binary and Application
  Support state directory.

Impact:

- Current and legacy noSleep files are cleaned.
- Uninstall remains conservative around ownership/type checks.

### 17. CLI command behavior clarified

Changed:

- Running `noSleep` without arguments now shows help.
- `noSleep daemon` is the explicit foreground daemon command.
- `doctor` labels daemon status as "Daemon" rather than "Sleep prevention" so
  an idle running daemon is not confused with an active sleep assertion.

Why:

- The original no-argument behavior ran the daemon directly.
- That made accidental daemon launches easier and blurred CLI versus daemon
  behavior.

Impact:

- Safer interactive usage.
- Clearer diagnostics.

### 18. C daemon safety checks

Changed:

- The C daemon is compiled with strict warnings promoted to errors:
  `-Wall`, `-Wextra`, `-Wpedantic`, `-Wconversion`, `-Wsign-conversion`,
  `-Wformat=2`, `-Wstrict-prototypes`, `-Wmissing-prototypes`, `-Wshadow`,
  `-Werror`, `-fstack-protector-strong`, and `-fvisibility=hidden`.
- The daemon is `clang --analyze` clean.
- Fixed-size buffers are bounded and checked.
- PID parsing rejects overflow and trailing junk.
- CoreFoundation and IOKit objects are explicitly released where owned.

Why:

- C gives lower runtime overhead but less memory safety than Swift.
- The C surface is intentionally small and warning-clean to reduce pointer and
  buffer-risk exposure.

Impact:

- Smaller daemon without ignoring C safety concerns.
- Future unsafe changes are more likely to fail the build.

### 19. Runtime validation performed

Observed on the local test machine after the final deployment:

```text
Process: noSleepDaemon
CPU: 0.0%
Threads: 1
Resident size: about 1504K
CPU time: about 00:00.01 during idle sampling
Page-ins: 2
Faults: stable during short idle samples
Open real fd: noSleep.lock
Logs: no noSleep log directory
```

Notes:

- These numbers are machine- and OS-version-specific.
- macOS can still show mapped runtime files such as `/usr/lib/dyld`, the
  executable, and cwd.
- macOS can still report page faults or page-ins for first access to executable
  and shared-library pages even when physical RAM is available.

### 20. Original behavior intentionally preserved

Preserved:

- Prevent system sleep only when AC power is connected and the lid is closed.
- Allow normal macOS behavior on battery or lid-open state.
- User commands: status, start, stop, restart, doctor, uninstall, help, version.
- `noSleep uninstall` remains the cleanup command.

Changed only where needed:

- daemon process architecture
- lock/state location
- lifecycle safety
- notification/sound mechanics
- install/uninstall cleanup
- runtime footprint

### 21. Launchd status and readiness fixed

Changed:

- CLI launchd checks now use `launchctl print gui/$UID/com.noSleep.daemon`
  instead of `launchctl list com.noSleep.daemon`.
- `noSleep start` and `noSleep restart` wait briefly for the daemon to write a
  validated lock PID before reporting success.
- `install.sh` uses the same GUI-domain launchd check and waits for daemon
  readiness when upgrading an already running install.

Why:

- On current macOS, `launchctl list <label>` from an interactive shell can fail
  even when the LaunchAgent is correctly loaded in the per-user GUI bootstrap
  domain.
- `launchctl bootstrap` can return before the daemon has finished startup and
  written its lock file, which made immediate `status`/`doctor` checks race.

Impact:

- `status` and `doctor` now agree with authoritative launchd state.
- `start`, `restart`, and installer upgrades do not claim success before the
  daemon is ready.

### 22. Direct daemon signal shutdown cleanup

Changed:

- The C daemon now handles direct `SIGTERM` and `SIGINT` through a
  kqueue-backed CoreFoundation run-loop source.
- Signal delivery stops the run loop and lets the normal cleanup path run.
- The signal path does not call CoreFoundation, IOKit, `flock`, `unlink`, or
  other non-signal-safe cleanup code from a raw POSIX signal handler.

Why:

- The CLI and installer already unload the daemon through launchd, and macOS
  releases power assertions when a process dies, but direct external
  termination should still give the daemon a chance to release its assertion,
  invalidate IOKit sources, release retained IOKit objects, and unlink its lock
  file in the same order as a normal shutdown.
- A naive C signal handler that calls the full cleanup routine would be
  incorrect because most cleanup APIs used here are not async-signal-safe.

Impact:

- More deterministic direct-kill behaviour.
- Cleaner lock-file cleanup if the daemon is terminated outside the CLI.
- No polling loop and no idle CPU work are added.
- Non-file-backed kqueue descriptors are kept for signal delivery and
  CoreFoundation run-loop integration; they are marked close-on-exec and do
  not create filesystem or SSD churn.

### 23. Sanitised notification and sound helper environment

Changed:

- `osascript` and `afplay` children now receive a fixed minimal environment:

```text
PATH=/usr/bin:/bin:/usr/sbin:/sbin
```

- They no longer inherit launchd/session variables such as `SSH_AUTH_SOCK`,
  `TMPDIR`, custom `PATH`, or `DYLD_*` values from the daemon process.
- Helper children reset `SIGTERM` and `SIGINT` to default handling at spawn
  time, so the daemon's own kqueue-based signal handling does not make child
  timeout cleanup less graceful.

Why:

- The daemon invokes helpers with absolute executable paths, so inheriting the
  full parent environment is unnecessary.
- A minimal environment reduces surprising helper behaviour and narrows the
  process boundary without changing notification or sound functionality.

Impact:

- Lower correctness and security risk around helper-process inheritance.
- Helper timeout handling remains bounded with a polite `SIGTERM` before the
  final `SIGKILL` fallback.
- Sounds and notifications remain enabled.
- Idle CPU, memory, and SSD behaviour are unchanged because helpers are only
  spawned on real power/lid state transitions.
