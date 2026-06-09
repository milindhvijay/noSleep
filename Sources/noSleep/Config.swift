// Config.swift - Global constants

import Foundation

let VERSION = "1.0.0"
// Must match the LaunchAgent plist Label.
let LABEL = "com.noSleep.daemon"
// Use the per-user temp directory so two different user accounts don't share a lock file.
let LOCKFILE: String = {
    let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
    return URL(fileURLWithPath: tmp).appendingPathComponent("noSleep.lock").path
}()
let PLIST_PATH = "\(NSHomeDirectory())/Library/LaunchAgents/\(LABEL).plist"
