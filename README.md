# noSleep

> Prevent macOS sleep when lid is closed on AC power. Event-driven daemon using native IOKit APIs.

[![Swift](https://img.shields.io/badge/Swift-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](https://developer.apple.com/macos/)
[![License](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE)

## Features

- **Event-driven** — No polling, uses IOKit callbacks for instant response
- **Lightweight** — ~80KB binary, minimal memory footprint  
- **Native** — Pure Swift, zero dependencies
- **launchd integration** — Auto-start on login, auto-restart on crash

## Behavior

| Condition | Sleep |
|-----------|-------|
| AC + Lid Closed | ❌ Prevented |
| AC + Lid Open | ✅ Allowed |
| Battery + Any | ✅ Allowed |

## Quick Install

```bash
./install.sh
noSleep start
```

This will compile, install to `~/bin`, set up launchd, and start the daemon.

## Usage

```bash
noSleep              # Run daemon (foreground)
noSleep status       # Show current state
noSleep start        # Start via launchd
noSleep stop         # Stop daemon
noSleep restart      # Restart daemon
noSleep doctor       # Run diagnostics
noSleep uninstall    # Remove all files
noSleep --help       # Show help
noSleep --version    # Show version
```

## Requirements

- Xcode Command Line Tools (`xcode-select --install`)

## How It Works

```mermaid
flowchart TB
    START([noSleep Daemon Starts]) --> MONITOR[Monitor Power & Lid State]
    
    MONITOR --> CHECK{AC Power AND Lid Closed?}
    
    CHECK -->|No| ALLOW_SLEEP[Allow Normal Sleep]
    CHECK -->|Yes| PREVENT[Prevent Sleep]
    
    PREVENT --> NOTIFY_ON["Sleep prevention active"]
    ALLOW_SLEEP --> NOTIFY_OFF["Normal behaviour restored"]
    
    NOTIFY_ON --> WAIT((Wait for Change))
    NOTIFY_OFF --> WAIT
    
    WAIT -->|Power/Lid Changes| MONITOR
```

## License

Licensed under GPLv3. See LICENSE file for details.
