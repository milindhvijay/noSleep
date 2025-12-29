// Config.swift - Global constants

import Foundation

let VERSION = "1.0.0"
// Must match the LaunchAgent plist Label.
let LABEL = "com.noSleep.daemon"
// /tmp keeps it simple and avoids permission surprises; we only need single-instance semantics.
let LOCKFILE = "/tmp/noSleep.lock"
let PLIST_PATH = "\(NSHomeDirectory())/Library/LaunchAgents/\(LABEL).plist"
