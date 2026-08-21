# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The project reports version 1.0.0 and carries no tagged releases, so entries are
grouped by the date each set of changes landed on the default branch.

## [Unreleased]

### Changed

- Documentation split into three files with distinct roles: `README.md` for
  install and usage, `DESIGN.md` for technical detail and rationale, and this
  changelog for history.
- `README.md` reorganized into conventional sections and trimmed of internals;
  troubleshooting is now keyed to the strings the CLI actually prints.
- `CHANGELOG.md` adopts Keep a Changelog format in place of the branch-named
  section and its numbered Changed/Why/Impact prose.

### Fixed

- Documented the Swift fallback daemon's actual behavior: it posts no
  notifications, plays no sounds, and debounces IOKit events, unlike the C
  daemon launchd runs.
- Documented all four restore-notification variants rather than only lid-close.
- Documented the installer's `-target-cpu` walk-down, `plutil -lint`
  validation, and restart-on-upgrade behavior.
- Documented kqueue-backed signal handling and the sanitized helper
  environment.
- Added `plutil` to the requirements list.
- Corrected `clang --analyze` from an implied build step to a manual check.

## 2026-07-24 — Daemon split and runtime hardening

The always-running process was a full Swift binary that also carried the CLI.
This change gives launchd a dedicated minimal daemon and hardens state handling,
lifecycle, and cleanup. The event-driven design was kept; no polling was
introduced.

### Added

- `noSleepDaemon`, a minimal C daemon that launchd runs in place of the Swift
  binary, so the resident process no longer carries CLI helpers, Foundation
  process-spawning utilities, or notification machinery.
- Swift fallback daemon retained behind `noSleep daemon`, which execs the
  installed daemon when present and runs the fallback otherwise.
- Reusable debounce timer in the Swift fallback to absorb duplicate IOKit event
  bursts.

### Changed

- Daemon state moved from `/tmp/noSleep.lock` to
  `~/Library/Application Support/noSleep/noSleep.lock`. `/tmp` is
  world-writable, which makes stale files, symlinks, and ownership surprises
  easy to hit for per-user daemon state. The legacy path is still read and
  cleaned when safe.
- CLI launchd checks use `launchctl print gui/$UID/com.noSleep.daemon` instead
  of `launchctl list com.noSleep.daemon`, which can fail from an interactive
  shell even when the agent is correctly loaded.
- Start, stop, restart, and uninstall address launchd through explicit service
  paths with `bootstrap`, `bootout`, and `kickstart`.
- Restart goes through launchd rather than replacing a running CLI process.
- The daemon no longer reads battery percentage; it only needs AC and lid
  state. `status` and `doctor` still report it.
- The `IOPMrootDomain` service is acquired once and cached for the process
  lifetime instead of being re-acquired on every lid read.
- Notifications fire only when the sleep assertion is actually created or
  released, so duplicate IOKit events no longer produce duplicate alerts.
- Lid close posts a notification without a sound; only the restore transition
  plays one. macOS can defer clamshell audio and replay it on lid open, where it
  stacked with the restore sound.
- The daemon closes stdin, stdout, and stderr after successful initialization.
- `doctor` labels daemon state as "Daemon" rather than "Sleep prevention", so an
  idle running daemon is not mistaken for an active assertion.
- `install.sh` requires both `swiftc` and `clang`, walks down through older
  `apple-m*` targets when the detected CPU is unsupported by the local
  compiler, removes empty compile logs, builds the daemon in a temporary path,
  validates the generated plist with `plutil -lint` before installing it, and
  seeds a standard system `PATH`.
- `install.sh` restarts an already-loaded daemon after writing the new binaries
  and plist, and waits for readiness before reporting success.
- `uninstall` covers the daemon binary and Application Support state directory
  in addition to the paths it already handled.

### Removed

- launchd log files. The plist directs stdout and stderr to `/dev/null` and the
  installer no longer creates `~/Library/Logs/noSleep`; `uninstall` still
  removes old log paths if present. The daemon does not log in normal
  operation, so the absence of that directory is intentional.

### Fixed

- `start`, `restart`, and installer upgrades no longer claim success before the
  daemon is ready. `launchctl bootstrap` can return before the daemon has
  written its lock file, which made immediate `status` and `doctor` checks race.
- Helper processes can no longer block a command or an event path indefinitely.
  Waits are bounded and escalate from `SIGTERM` to `SIGKILL`, and children are
  reaped, so no zombies are left behind.
- A direct `SIGTERM` or `SIGINT` now releases the sleep assertion, invalidates
  the IOKit sources, releases retained IOKit objects, and unlinks the lock file
  in the same order as a normal shutdown.

### Security

- Lock files are opened with `O_NOFOLLOW` and `O_CLOEXEC`, so a symlink at that
  path is refused rather than followed.
- Lock files are validated after opening for file type, owner, and hardlink
  count, rejecting hardlink and file-type substitution.
- The state directory is created mode `0700` and the lock file mode `0600`,
  replacing the previous `0644`.
- PID writes use a full-write loop flushed with `fsync`, so a partial write
  cannot leave a truncated PID behind.
- The lock file is unlinked before the advisory lock is released, so another
  process cannot acquire the lock on an inode that is about to be deleted.
- PIDs are validated with `proc_pidpath` before being trusted or signaled, so a
  recycled PID is not reported as a running daemon. The C daemon additionally
  rejects PID text that overflows or carries trailing junk.
- The daemon spawns notification and sound helpers with `posix_spawn` and
  absolute paths instead of shell strings.
- Helper children receive a fixed minimal environment
  (`PATH=/usr/bin:/bin:/usr/sbin:/sbin`) rather than inheriting the daemon's
  `TMPDIR`, `SSH_AUTH_SOCK`, custom `PATH`, or `DYLD_*` values, and have
  `SIGTERM` and `SIGINT` reset to default.
- Signals are handled through a kqueue-backed CoreFoundation run-loop source
  rather than a raw POSIX handler, since the cleanup path calls
  CoreFoundation, IOKit, `flock`, and `unlink`, none of which are
  async-signal-safe.
- File and directory removal during uninstall checks ownership and expected
  type, so only paths owned by the current user are touched.
- The C daemon is compiled with warnings promoted to errors (`-Wall`,
  `-Wextra`, `-Wpedantic`, `-Wconversion`, `-Wsign-conversion`, `-Wformat=2`,
  `-Wstrict-prototypes`, `-Wmissing-prototypes`, `-Wshadow`, `-Werror`) plus
  `-fstack-protector-strong` and `-fvisibility=hidden`. Fixed-size buffers are
  bounded and checked, and CoreFoundation and IOKit objects are released where
  owned.

## 2026-05-12 — Subprocess and lifecycle hardening

### Added

- `noSleep daemon` subcommand for explicit foreground daemon mode.

### Changed

- Bare `noSleep` prints help instead of running the daemon, so an accidental
  invocation no longer starts a daemon.
- `install.sh` detects Apple silicon and attempts a `-target-cpu` optimized
  build with a clean fallback.
- `install.sh` detects a previously loaded daemon and restarts it after install,
  so upgrades pick up the new `daemon` ProgramArgument without manual steps.

### Fixed

- `start` is idempotent and surfaces `launchctl bootstrap` failures instead of
  reporting success unconditionally; `restart` was given the same handling.

### Security

- Replaced `shell()` with `run()`, which executes binaries directly through
  `Process` and `executableURL`. This removes the shell-injection vector and the
  manual quote escaping it required.
- Added a `DispatchSemaphore`-based timeout to `run()`, with optional stderr
  suppression, so a stuck helper cannot hang a command.
- Restored AppleScript-level escaping of backslashes and quotes in `notify()`.
  `run()` removes shell injection, but the message is still interpolated into an
  AppleScript string literal, so dynamic content containing a quote would
  otherwise produce a malformed script.

## 2025-12-22 — Initial implementation

### Added

- Swift daemon that holds an `IOPMAssertion` to prevent system sleep while the
  lid is closed on AC power, driven by IOKit clamshell and power-source
  notifications rather than polling.
- CLI with `status`, `start`, `stop`, `restart`, `doctor`, `uninstall`, help,
  and version.
- Single-instance locking through a PID lock file.
- Notification and sound feedback on state transitions.
- `install.sh`, which compiles the binary into `~/bin` and installs a launchd
  agent that starts the daemon at login.
- `uninstall`, which stops the daemon, removes installed files and log files,
  and prints each path it removed.

### Fixed

- Use `kIOPMAssertionTypePreventSystemSleep` instead of
  `kIOPMAssertPreventUserIdleSystemSleep`. The idle-sleep assertion does not
  hold across a clamshell close, which is the case the tool exists for.
- Pin `install.sh` to zsh rather than relying on the invoking shell.
