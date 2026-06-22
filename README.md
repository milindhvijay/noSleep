# noSleep

noSleep is a small macOS utility that keeps a Mac awake when the lid is closed
and AC power is connected.

The current build separates the human-facing CLI from the long-running daemon:

- `noSleep`: Swift CLI for install-time and user commands.
- `noSleepDaemon`: minimal C daemon run by `launchd`.

This keeps the always-running process small while preserving the original user
commands and behavior.

## Behavior

| State | Result |
| --- | --- |
| AC power connected and lid closed | Prevent system sleep |
| AC power connected and lid open | Allow normal macOS behavior |
| Battery power | Allow normal macOS behavior |

Closing the lid posts a "Sleep prevention active" notification. Opening the lid
or switching out of the protected state posts a restore notification and plays a
single restore sound. The lid-close sound is intentionally suppressed because
macOS can defer audio during clamshell transitions and replay it on lid-open.

## Requirements

- macOS
- Xcode Command Line Tools
- `swiftc`
- `clang`
- `launchctl`

Install Xcode Command Line Tools if needed:

```sh
xcode-select --install
```

## Install

```sh
./install.sh
noSleep start
```

The installer:

- builds the Swift CLI as `~/bin/noSleep`
- builds the minimal daemon as `~/bin/noSleepDaemon`
- creates `~/Library/Application Support/noSleep`
- installs `~/Library/LaunchAgents/com.noSleep.daemon.plist`
- points launchd stdout and stderr at `/dev/null`
- validates the generated plist with `plutil -lint`

The installer intentionally leaves the local `./noSleep` build artifact in the
repository directory.

## Commands

```sh
noSleep              # Show help
noSleep status       # Show power, lid, daemon, and launchd state
noSleep start        # Start the daemon via launchd
noSleep stop         # Stop the daemon but keep installed files
noSleep restart      # Restart the daemon via launchd
noSleep doctor       # Run read-only diagnostics
noSleep daemon       # Exec the installed daemon, or run Swift fallback
noSleep uninstall    # Stop and remove installed files
noSleep --version    # Show version
noSleep --help       # Show help
```

## Runtime Footprint

The daemon is event-driven. It does not poll. It listens for IOKit clamshell and
power-source notifications, then creates or releases one
`PreventSystemSleep` assertion.

Expected idle shape after startup:

- one daemon thread
- no stdout/stderr log files
- one lock-file descriptor
- no polling loop
- no permanent notification worker thread

Typical open-file view:

```text
/
~/bin/noSleepDaemon
/usr/lib/dyld
~/Library/Application Support/noSleep/noSleep.lock
```

Activity Monitor and `lsof` also report mapped runtime objects such as the
executable and `dyld`; those are not files created by noSleep.

macOS may still report page faults or page-ins for first access to executable
or shared library pages. noSleep cannot force those counters to zero, but the
daemon is structured to avoid idle churn.

## Installed Files

Current install:

```text
~/bin/noSleep
~/bin/noSleepDaemon
~/Library/LaunchAgents/com.noSleep.daemon.plist
~/Library/Application Support/noSleep/noSleep.lock
```

Legacy cleanup support:

```text
/tmp/noSleep.lock
/tmp/noSleep.log
/tmp/noSleep.err
~/Library/Logs/noSleep
```

`noSleep uninstall` removes the installed binaries, launchd plist, lock file,
state directory, and legacy cleanup paths when they are owned by the current
user and safe to remove.

## Design Notes

The original Swift-only daemon was simple and readable, but the long-running
process also carried CLI helpers, Foundation process-spawning utilities, and
notification code. The current design keeps that code in the CLI path and runs
a smaller dedicated daemon under launchd.

Security and correctness hardening includes:

- state directory under `~/Library/Application Support/noSleep`
- lock file created with `O_NOFOLLOW`, `O_CLOEXEC`, and mode `0600`
- lock-file owner, type, and hardlink validation
- full-write PID update with `fsync`
- PID validation through `proc_pidpath`
- direct `Process` usage in Swift instead of shell strings
- direct `posix_spawn` in the daemon for notifications and sounds
- strict C compiler warnings promoted to errors
- `clang --analyze` clean daemon source

## Troubleshooting

Check current state:

```sh
noSleep status
noSleep doctor
```

Restart the daemon:

```sh
noSleep restart
```

Fully remove the install:

```sh
noSleep uninstall
```

If the daemon is running but the current shell cannot find `noSleep`, make sure
`~/bin` is in your `PATH`.

## License

GPLv3. See [LICENSE](LICENSE).
