// Commands.swift

import Foundation

@discardableResult
// Lightweight helper for running system tools.
// We intentionally discard output to avoid Pipe buffering/allocation overhead.
private func runProcess(_ launchPath: String, _ arguments: [String]) -> Int32 {
    autoreleasepool {
        let task = Process()
        // Use executableURL rather than launchPath/launch() (launch is deprecated).
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments

        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return 1
        }

        return task.terminationStatus
    }
}

@discardableResult
// launchctl is the only supported way to manage the LaunchAgent from a CLI tool.
// Using it directly avoids spawning a shell and avoids fragile string parsing.
private func runLaunchctl(_ arguments: [String]) -> Int32 {
    runProcess("/bin/launchctl", arguments)
}

private func isLaunchdJobLoaded() -> Bool {
    let domain = "gui/\(getUID())/\(LABEL)"
    // 'launchctl print' is a cheap existence check: status 0 means the job is loaded.
    let status = runLaunchctl(["print", domain])
    return status == 0
}

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
    
    print("launchd: \(isLaunchdJobLoaded() ? "LOADED" : "NOT loaded")")
}

func cmdStart() {
    print("[noSleep] Starting via launchctl")
    _ = runLaunchctl(["enable", "gui/\(getUID())/\(LABEL)"])
    _ = runLaunchctl(["bootstrap", "gui/\(getUID())", PLIST_PATH])
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
    
    _ = runLaunchctl(["bootout", "gui/\(getUID())", PLIST_PATH])
    _ = runLaunchctl(["disable", "gui/\(getUID())/\(LABEL)"])
    
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
    
    _ = runLaunchctl(["bootout", "gui/\(getUID())", PLIST_PATH])
    _ = runLaunchctl(["disable", "gui/\(getUID())/\(LABEL)"])
    
    if let pid = daemonPID {
        for _ in 0..<50 {
            if kill(pid, 0) != 0 { break }
            usleep(100_000)
        }
    }
    
    try? FileManager.default.removeItem(atPath: LOCKFILE)
    
    _ = runLaunchctl(["enable", "gui/\(getUID())/\(LABEL)"])
    _ = runLaunchctl(["bootstrap", "gui/\(getUID())", PLIST_PATH])
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
    
    let launchdStatus = isLaunchdJobLoaded() ? "Loaded" : "Not loaded"

    let plistStatus = runProcess("/usr/bin/plutil", ["-lint", PLIST_PATH]) == 0 ? "Valid" : "Missing or invalid"
    
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

    _ = runLaunchctl(["bootout", "gui/\(getUID())", PLIST_PATH])
    _ = runLaunchctl(["disable", "gui/\(getUID())/\(LABEL)"])
    
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
