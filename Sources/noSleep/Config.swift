// Config.swift - Global constants

import Foundation

let VERSION = "1.0.0"
let LABEL = "com.noSleep.daemon"
let APP_DIR = "\(NSHomeDirectory())/Library/Application Support/noSleep"
let LOG_DIR = "\(NSHomeDirectory())/Library/Logs/noSleep"
let LOCKFILE = "\(APP_DIR)/noSleep.lock"
let LEGACY_LOCKFILE = "/tmp/noSleep.lock"
let LOG_PATH = "\(LOG_DIR)/noSleep.log"
let ERROR_LOG_PATH = "\(LOG_DIR)/noSleep.err"
let LEGACY_LOG_PATH = "/tmp/noSleep.log"
let LEGACY_ERROR_LOG_PATH = "/tmp/noSleep.err"
let DAEMON_PATH = "\(NSHomeDirectory())/bin/noSleepDaemon"
let PLIST_PATH = "\(NSHomeDirectory())/Library/LaunchAgents/\(LABEL).plist"
let UID = "\(getuid())"
