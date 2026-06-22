// Utilities.swift

import Darwin
import Foundation

@discardableResult
func run(_ executable: String, _ args: String..., suppressStderr: Bool = false, captureOutput: Bool = true, timeout: TimeInterval = 5) -> (output: String, status: Int32) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = args
    task.standardError = suppressStderr ? FileHandle.nullDevice : nil

    var pipe: Pipe?
    if captureOutput {
        let p = Pipe()
        task.standardOutput = p
        pipe = p
    } else {
        task.standardOutput = FileHandle.nullDevice
    }

    let semaphore = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in semaphore.signal() }

    do {
        try task.run()
    } catch {
        fputs("[ERROR] Unable to run \(executable): \(error)\n", stderr)
        return ("", -1)
    }

    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        task.terminate()
        if semaphore.wait(timeout: .now() + 1) == .timedOut {
            return ("", -1)
        }
        return ("", -1)
    }

    if let p = pipe {
        let data = p.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "", task.terminationStatus)
    }
    return ("", task.terminationStatus)
}

func processIsRunning(_ pid: Int32) -> Bool {
    guard pid > 1 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

func isNoSleepProcess(_ pid: Int32) -> Bool {
    var pathBuffer = [CChar](repeating: 0, count: 4096)
    let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
    guard pathLength > 0 else { return false }

    let processPath = String(cString: pathBuffer)
    let processName = URL(fileURLWithPath: processPath).lastPathComponent
    return processName == "noSleep"
        || processName == "noSleepDaemon"
        || processPath == "\(NSHomeDirectory())/bin/noSleep"
        || processPath == DAEMON_PATH
}

private func checkedDaemonPID(from path: String) -> Int32? {
    guard let pid = readLockPID(from: path),
          processIsRunning(pid),
          isNoSleepProcess(pid) else {
        return nil
    }

    return pid
}

func readDaemonPID() -> Int32? {
    for path in [LOCKFILE, LEGACY_LOCKFILE] {
        if let pid = checkedDaemonPID(from: path) {
            return pid
        }
    }

    return nil
}

func readDaemonLockFilePath() -> String? {
    for path in [LOCKFILE, LEGACY_LOCKFILE] {
        if checkedDaemonPID(from: path) != nil {
            return path
        }
    }

    return nil
}

@discardableResult
func waitForProcessExit(_ pid: Int32, attempts: Int = 50) -> Bool {
    for _ in 0..<attempts {
        if !processIsRunning(pid) { return true }
        usleep(100_000)
    }

    return !processIsRunning(pid)
}

func execInstalledDaemonOrRunFallback() {
    if access(DAEMON_PATH, X_OK) == 0 {
        let argv0 = strdup(DAEMON_PATH)
        var argv: [UnsafeMutablePointer<CChar>?] = [argv0, nil]
        execv(DAEMON_PATH, &argv)
        free(argv0)
        fputs("[ERROR] Unable to exec \(DAEMON_PATH): \(String(cString: strerror(errno)))\n", stderr)
        exit(1)
    }

    runDaemon()
}
