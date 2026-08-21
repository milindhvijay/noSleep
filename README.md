# noSleep

A small macOS utility that keeps your Mac awake while the lid is closed and AC
power is connected. On battery, or with the lid open, macOS sleep behavior is
left alone.

## Behavior

| Power | Lid | Result |
| --- | --- | --- |
| AC | Closed | Sleep prevented |
| AC | Open | macOS default |
| Battery | Any | macOS default |

A notification is posted when sleep prevention starts and when normal behavior
is restored.

## Requirements

- macOS
- Xcode Command Line Tools

```sh
xcode-select --install
```

## Installation

```sh
./install.sh
noSleep start
```

The installer builds `noSleep` and `noSleepDaemon` into `~/bin` and installs a
launch agent at `~/Library/LaunchAgents/com.noSleep.daemon.plist`, so the daemon
starts at login. If `~/bin` is not on your `PATH`, add it to your `~/.zshrc`:

```sh
export PATH="$HOME/bin:$PATH"
```

To upgrade, re-run `./install.sh`. A running daemon is restarted automatically.

## Usage

```
noSleep status       Show power, lid, and daemon state
noSleep start        Start the daemon via launchd
noSleep stop         Stop the daemon
noSleep restart      Restart the daemon
noSleep daemon       Run the daemon in the foreground
noSleep doctor       Print diagnostics (read-only)
noSleep uninstall    Stop the daemon and remove all installed files
noSleep --help       Show help
noSleep --version    Show version
```

## How it works

noSleep ships two binaries. `noSleep` is a Swift CLI for install-time and
lifecycle commands. `noSleepDaemon` is a minimal C daemon run by launchd, which
keeps the always-running process small.

The daemon is event-driven and does not poll. It watches IOKit clamshell
(`AppleClamshellState`) and power-source notifications, and holds exactly one
`kIOPMAssertionTypePreventSystemSleep` assertion while the lid is closed on AC
power — the assertion type that survives a clamshell close. At idle it is one
thread with one open file descriptor, its lock file, and it writes no logs.

A single instance is enforced with an `flock` on
`~/Library/Application Support/noSleep/noSleep.lock`. The PID in that file is
validated with `proc_pidpath` before it is reported or signaled, so a recycled
PID is never mistaken for a running daemon.

See [DESIGN.md](DESIGN.md) for the full technical notes, including the locking
and security model, signal handling, and build hardening.

## Installed files

```text
~/bin/noSleep
~/bin/noSleepDaemon
~/Library/LaunchAgents/com.noSleep.daemon.plist
~/Library/Application Support/noSleep/noSleep.lock
```

The state directory is created mode `0700` and the lock file mode `0600`. The
launch agent directs stdout and stderr to `/dev/null`; noSleep creates no log
files.

## Uninstall

```sh
noSleep uninstall
```

This removes the binaries, launch agent, lock file, and state directory, along
with legacy `/tmp/noSleep.*` and `~/Library/Logs/noSleep` paths from older
versions. Each removal checks ownership and file type first — only paths owned
by the current user are touched — and prints what it removed.

## Troubleshooting

Start with the two read-only commands. `status` reports power, lid, daemon, and
launchd state; `doctor` adds the plist, binary, and lock file it found.

```sh
noSleep status
noSleep doctor
```

**`noSleep: command not found`** — `~/bin` is not on your `PATH`. See
[Installation](#installation).

**`Daemon: NOT running` or `launchd: NOT loaded`** — run `noSleep start`. If
that fails with `Failed to start daemon`, the launch agent is missing or
invalid; re-run `./install.sh`.

**The Mac still sleeps with the lid closed on AC** — confirm `noSleep status`
reports both `Power: AC` and `Lid: Closed`. If it does and the daemon is
running, restart it to re-create the assertion:

```sh
noSleep restart
```

## License

GPLv3. See [LICENSE](LICENSE).
