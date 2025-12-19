// Lock.swift

import Foundation

var lockFD: Int32 = -1

func acquireLock() -> Bool {
    lockFD = open(LOCKFILE, O_CREAT | O_RDWR, 0o644)
    guard lockFD >= 0 else { return false }
    
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        close(lockFD)
        lockFD = -1
        return false
    }
    
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
