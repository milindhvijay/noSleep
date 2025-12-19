// Commands.swift

import Foundation

func cmdStatus() {
    print("---- noSleep status ----")
    
    let state = getCurrentPowerState()
    print("Power: \(state.isOnAC ? "AC" : "Battery")")
    print("Lid: \(state.isLidClosed ? "Closed" : "Open")")
    
    if let data = FileManager.default.contents(atPath: LOCKFILE),
       let pidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       let pid = Int32(pidStr),
       kill(pid, 0) == 0 {
        print("Daemon: RUNNING (pid \(pid))")
    } else {
        print("Daemon: NOT running")
    }
    
    let (output, _) = shell("launchctl list | grep '\(LABEL)'")
    print("launchd: \(output.contains(LABEL) ? "LOADED" : "NOT loaded")")
}

func cmdStart() {
    print("[noSleep] Starting via launchctl")
    shell("launchctl enable gui/\(getUID())/\(LABEL)")
    shell("launchctl bootstrap gui/\(getUID()) '\(PLIST_PATH)'")
    print("[noSleep] Started")
}

func cmdStop() {
    print("[noSleep] Stopping via launchctl")
    
    var daemonPID: Int32? = nil
    if let data = FileManager.default.contents(atPath: LOCKFILE),
       let pidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       let pid = Int32(pidStr) {
        daemonPID = pid
    }
    
    shell("launchctl bootout gui/\(getUID()) '\(PLIST_PATH)' 2>/dev/null || true")
    shell("launchctl disable gui/\(getUID())/\(LABEL) 2>/dev/null || true")
    
    if let pid = daemonPID {
        for _ in 0..<50 {  // 5 sec max
            if kill(pid, 0) != 0 { break }
            usleep(100_000)
        }
    }
    
    try? FileManager.default.removeItem(atPath: LOCKFILE)
    
    if let pid = daemonPID {
        print("[noSleep] Stopped (pid \(pid))")
    } else {
        print("[noSleep] Stopped")
    }
}

func cmdRestart() {
    print("[noSleep] Restarting via launchctl")
    
    var daemonPID: Int32? = nil
    if let data = FileManager.default.contents(atPath: LOCKFILE),
       let pidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       let pid = Int32(pidStr) {
        daemonPID = pid
        kill(pid, SIGTERM)
    }
    
    shell("launchctl bootout gui/\(getUID()) '\(PLIST_PATH)' 2>/dev/null || true")
    shell("launchctl disable gui/\(getUID())/\(LABEL) 2>/dev/null || true")
    
    if let pid = daemonPID {
        for _ in 0..<50 {
            if kill(pid, 0) != 0 { break }
            usleep(100_000)
        }
    }
    
    try? FileManager.default.removeItem(atPath: LOCKFILE)
    
    shell("launchctl enable gui/\(getUID())/\(LABEL)")
    shell("launchctl bootstrap gui/\(getUID()) '\(PLIST_PATH)'")
    print("[noSleep] Restarted")
}

func cmdDoctor() {
    print("noSleep v\(VERSION) - Diagnostics (read-only)\n")
    
    let state = getCurrentPowerState()
    let binaryPath = CommandLine.arguments[0]
    
    var daemonStatus = "Inactive"
    if let data = FileManager.default.contents(atPath: LOCKFILE),
       let pidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       let pid = Int32(pidStr),
       kill(pid, 0) == 0 {
        daemonStatus = "Active (pid \(pid))"
    }
    
    let (launchctl, _) = shell("launchctl list | grep '\(LABEL)' 2>&1")
    let launchdStatus = launchctl.isEmpty ? "Not loaded" : "Loaded"
    
    let (plutil, _) = shell("plutil -lint '\(PLIST_PATH)' 2>&1")
    let plistStatus = plutil.contains("OK") ? "Valid" : "Missing or invalid"
    
    print("""
    SYSTEM STATE:
        Power            \(state.isOnAC ? "AC" : "Battery")\(state.batteryPercent.map { " (\($0)%)" } ?? "")
        Lid              \(state.isLidClosed ? "Closed" : "Open")
        Sleep prevention \(daemonStatus)
    
    SERVICE:
        launchd          \(launchdStatus)
        Plist            \(plistStatus)
        Binary           \(binaryPath)
        Lock file        \(FileManager.default.fileExists(atPath: LOCKFILE) ? LOCKFILE : "None")
    """)
}

func cmdUninstall() {
    print("[noSleep] Uninstalling...")
    
    shell("launchctl bootout gui/\(getUID()) '\(PLIST_PATH)' 2>/dev/null || true")
    shell("launchctl disable gui/\(getUID())/\(LABEL) 2>/dev/null || true")
    
    if let data = FileManager.default.contents(atPath: LOCKFILE),
       let pidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       let pid = Int32(pidStr) {
        kill(pid, SIGTERM)
        for _ in 0..<30 {
            if kill(pid, 0) != 0 { break }
            usleep(100_000)
        }
    }
    
    if FileManager.default.fileExists(atPath: PLIST_PATH) {
        do {
            try FileManager.default.removeItem(atPath: PLIST_PATH)
            print("   Removed: \(PLIST_PATH)")
        } catch {
            print("   Warning: Could not remove \(PLIST_PATH)")
        }
    }
    
    let binPath = NSHomeDirectory() + "/bin/noSleep"
    if FileManager.default.fileExists(atPath: binPath) {
        do {
            try FileManager.default.removeItem(atPath: binPath)
            print("   Removed: \(binPath)")
        } catch {
            print("   Warning: Could not remove \(binPath)")
        }
    }
    
    if FileManager.default.fileExists(atPath: LOCKFILE) {
        try? FileManager.default.removeItem(atPath: LOCKFILE)
        print("   Removed: \(LOCKFILE)")
    }
    if FileManager.default.fileExists(atPath: "/tmp/noSleep.log") {
        try? FileManager.default.removeItem(atPath: "/tmp/noSleep.log")
        print("   Removed: /tmp/noSleep.log")
    }
    if FileManager.default.fileExists(atPath: "/tmp/noSleep.err") {
        try? FileManager.default.removeItem(atPath: "/tmp/noSleep.err")
        print("   Removed: /tmp/noSleep.err")
    }
    print("[noSleep] Uninstall complete")
}
