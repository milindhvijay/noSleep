// Commands.swift

import Foundation

private let launchdDomain = "gui/\(UID)"
private let launchdService = "\(launchdDomain)/\(LABEL)"

private func launchdServiceIsLoaded() -> Bool {
    let (_, status) = run(
        "/bin/launchctl",
        "print",
        launchdService,
        suppressStderr: true,
        captureOutput: false
    )
    return status == 0
}

private func enableLaunchdDaemon() {
    run(
        "/bin/launchctl",
        "enable",
        launchdService,
        suppressStderr: true,
        captureOutput: false
    )
}

private func bootstrapLaunchdDaemon() -> Bool {
    let (_, status) = run(
        "/bin/launchctl",
        "bootstrap",
        launchdDomain,
        PLIST_PATH
    )
    return status == 0
}

private func kickstartLaunchdDaemon() -> Bool {
    let (_, status) = run(
        "/bin/launchctl",
        "kickstart",
        "-k",
        launchdService,
        suppressStderr: true,
        captureOutput: false
    )
    return status == 0
}

private func waitForDaemonStart(previousPID: Int32? = nil, attempts: Int = 50) -> Int32? {
    for _ in 0..<attempts {
        if let pid = readDaemonPID(), pid != previousPID {
            return pid
        }
        usleep(100_000)
    }

    if let pid = readDaemonPID(), pid != previousPID {
        return pid
    }
    return nil
}

private func stopDaemonIfNeeded(_ daemonPID: Int32?, waitAttempts: Int = 50) {
    guard let pid = daemonPID else { return }

    if waitForProcessExit(pid, attempts: waitAttempts) { return }

    if isNoSleepProcess(pid) {
        kill(pid, SIGTERM)
        _ = waitForProcessExit(pid, attempts: 30)
    }
}

private func unloadLaunchdDaemon(_ daemonPID: Int32?, waitAttempts: Int = 50) {
    run("/bin/launchctl", "bootout", launchdService, suppressStderr: true, captureOutput: false)
    run("/bin/launchctl", "disable", launchdService, suppressStderr: true, captureOutput: false)
    stopDaemonIfNeeded(daemonPID, waitAttempts: waitAttempts)
}

private func stopDaemonAfterUninstall(_ daemonPID: Int32?) {
    enableLaunchdDaemon()
    let (_, bootoutCode) = run(
        "/bin/launchctl",
        "bootout",
        launchdService,
        suppressStderr: true,
        captureOutput: false
    )

    if bootoutCode != 0 {
        run("/bin/launchctl", "disable", launchdService, suppressStderr: true, captureOutput: false)
        stopDaemonIfNeeded(daemonPID, waitAttempts: 30)
        run("/bin/launchctl", "bootout", launchdService, suppressStderr: true, captureOutput: false)
        enableLaunchdDaemon()
        return
    }

    stopDaemonIfNeeded(daemonPID, waitAttempts: 30)
}

private func removeInstalledFile(_ path: String) {
    if removeOwnedFileIfPresent(path) {
        print("   Removed: \(path)")
    }
}

private func removeInstalledDirectory(_ path: String) {
    if removeOwnedDirectoryIfPresent(path) {
        print("   Removed: \(path)")
    }
}

private func removeInstalledItems() {
    removeInstalledFile(PLIST_PATH)
    removeInstalledFile(NSHomeDirectory() + "/bin/noSleep")
    removeInstalledFile(DAEMON_PATH)
    removeInstalledFile(LOCKFILE)
    removeInstalledFile(LOG_PATH)
    removeInstalledFile(ERROR_LOG_PATH)
    removeInstalledFile(LEGACY_LOCKFILE)
    removeInstalledFile(LEGACY_LOG_PATH)
    removeInstalledFile(LEGACY_ERROR_LOG_PATH)
    removeInstalledDirectory(LOG_DIR)
    removeInstalledDirectory(APP_DIR)
}

func cmdStatus() {
    print("---- noSleep status ----")

    let state = getCurrentPowerState()
    print("Power: \(state.isOnAC ? "AC" : "Battery")")
    print("Lid: \(state.isLidClosed ? "Closed" : "Open")")

    if let pid = readDaemonPID() {
        print("Daemon: RUNNING (pid \(pid))")
    } else {
        print("Daemon: NOT running")
    }

    print("launchd: \(launchdServiceIsLoaded() ? "LOADED" : "NOT loaded")")
}

func cmdStart() {
    if launchdServiceIsLoaded(), readDaemonPID() != nil {
        print("[noSleep] Already running")
        return
    }

    print("[noSleep] Starting via launchctl")
    enableLaunchdDaemon()

    let started = launchdServiceIsLoaded()
        ? kickstartLaunchdDaemon()
        : bootstrapLaunchdDaemon()

    if !started || waitForDaemonStart() == nil {
        fputs("[ERROR] Failed to start daemon (is the plist installed? Run install.sh)\n", stderr)
        exit(1)
    }
    print("[noSleep] Started")
}

func cmdStop() {
    print("[noSleep] Stopping via launchctl")

    let daemonPID = readDaemonPID()
    unloadLaunchdDaemon(daemonPID)

    removeLockFileIfSafe()
    _ = removeOwnedFileIfPresent(LEGACY_LOCKFILE)

    if let pid = daemonPID {
        print("[noSleep] Stopped (pid \(pid))")
    } else {
        print("[noSleep] Stopped")
    }
}

func cmdRestart() {
    print("[noSleep] Restarting via launchctl")

    let daemonPID = readDaemonPID()

    if launchdServiceIsLoaded() {
        enableLaunchdDaemon()
        if kickstartLaunchdDaemon(),
           waitForDaemonStart(previousPID: daemonPID) != nil {
            print("[noSleep] Restarted")
            return
        }
    }

    unloadLaunchdDaemon(daemonPID)
    removeLockFileIfSafe()
    _ = removeOwnedFileIfPresent(LEGACY_LOCKFILE)

    enableLaunchdDaemon()
    if !bootstrapLaunchdDaemon() || waitForDaemonStart(previousPID: daemonPID) == nil {
        fputs("[ERROR] Failed to start daemon (is the plist installed? Run install.sh)\n", stderr)
        exit(1)
    }
    print("[noSleep] Restarted")
}

func cmdDoctor() {
    print("noSleep v\(VERSION) - Diagnostics (read-only)\n")

    let state = getCurrentPowerState()
    let binaryPath = CommandLine.arguments[0]

    var daemonStatus = "Not running"
    if let pid = readDaemonPID() {
        daemonStatus = "Running (pid \(pid))"
    }

    let launchdStatus = launchdServiceIsLoaded() ? "Loaded" : "Not loaded"

    let (plutilOutput, _) = run("/usr/bin/plutil", "-lint", PLIST_PATH)
    let plistStatus = plutilOutput.contains("OK") ? "Valid" : "Missing or invalid"

    print("""
    SYSTEM STATE:
        Power            \(state.isOnAC ? "AC" : "Battery")\(state.batteryPercent.map { " (\($0)%)" } ?? "")
        Lid              \(state.isLidClosed ? "Closed" : "Open")
        Daemon           \(daemonStatus)

    SERVICE:
        launchd          \(launchdStatus)
        Plist            \(plistStatus)
        Binary           \(binaryPath)
        Daemon binary    \(DAEMON_PATH)
        Lock file        \(readDaemonLockFilePath() ?? "None")
    """)
}

func cmdUninstall() {
    print("[noSleep] Uninstalling...")

    let daemonPID = readDaemonPID()

    removeInstalledItems()
    stopDaemonAfterUninstall(daemonPID)
    removeInstalledItems()
    print("[noSleep] Uninstall complete")
}
