// Lock.swift

import Foundation

// Simple single-instance guard.
// We keep the file descriptor open for the life of the process so the advisory lock stays held.
var lockFD: Int32 = -1

func acquireLock() -> Bool {
    lockFD = open(LOCKFILE, O_CREAT | O_RDWR, 0o644)
    guard lockFD >= 0 else { return false }
    
    // flock is advisory, but it's enough for "don't run two daemons at once".
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        close(lockFD)
        lockFD = -1
        return false
    }
    
    // Helpful for tooling/debugging: write the PID into the lock file.
    ftruncate(lockFD, 0)
    let pidStr = "\(getpid())\n"
    write(lockFD, pidStr, pidStr.count)
    return true
}

func releaseLock() {
    if lockFD >= 0 {
        flock(lockFD, LOCK_UN)
        close(lockFD)
        unlink(LOCKFILE)
        lockFD = -1
    }
}
