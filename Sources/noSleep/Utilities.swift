// Utilities.swift

import Foundation
import Darwin

@inline(__always)
func getUID() -> String {
    "\(getuid())"
}

// We use osascript because UNUserNotificationCenter requires a bundled app.
// This keeps the project a single small binary, but we need to be careful not to spam process launches.

// Static constants to avoid repeated allocations.
private let kMinNotifyIntervalSeconds: CFTimeInterval = 2.0

// Simple timestamp-based rate limiting. No timers, no allocations on hot path.
private var gNotifyLastFireTime: CFAbsoluteTime = 0

// Single-pass AppleScript string escaping.
@inline(__always)
private func escapeAppleScript(_ s: String) -> String {
    var result = ""
    result.reserveCapacity(s.count + 8)
    for c in s {
        switch c {
        case "\\": result += "\\\\"
        case "\"": result += "\\\""
        default:   result.append(c)
        }
    }
    return result
}

func notify(_ message: String, subtitle: String? = nil, sound: String = "Glass") {
    // Rate-limit: skip if called too soon (next state change will retry).
    let now = CFAbsoluteTimeGetCurrent()
    if gNotifyLastFireTime != 0 && (now - gNotifyLastFireTime) < kMinNotifyIntervalSeconds {
        return
    }
    gNotifyLastFireTime = now

    // Build the AppleScript command.
    var script = "display notification \"\(escapeAppleScript(message))\" with title \"noSleep\""
    if let sub = subtitle {
        script += " subtitle \"\(escapeAppleScript(sub))\""
    }
    script += " sound name \"\(escapeAppleScript(sound))\""

    // Use posix_spawn directly instead of Foundation's Process class (lighter weight).
    // Fire-and-forget: we don't wait for completion.
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [
        strdup("/usr/bin/osascript"),
        strdup("-e"),
        strdup(script),
        nil
    ]
    defer { for arg in argv { free(arg) } }
    
    // Redirect stdout/stderr to /dev/null
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    
    posix_spawn(&pid, "/usr/bin/osascript", &fileActions, nil, argv, nil)
}

func notifyPreventing() {
    notify("Sleep Prevention Active", subtitle: "AC Power + Lid Closed", sound: "Hero")
}

func notifyRestored(reason: String) {
    notify("Normal Behaviour Restored", subtitle: reason, sound: "Glass")
}
